# Internal deps
require File.join(File.dirname(__FILE__), 'base_probe')

module Nagios
  module Promoo
    module Appdb
      module Probes
        # Probe for checking appliance synchronization between sites and AppDB.
        #
        # @author Boris Parak <parak@cesnet.cz>
        class SyncProbe < Nagios::Promoo::Appdb::Probes::BaseProbe
          class << self
            def description
              [
                'sync',
                'Run a probe checking consistency between a published VO-wide ' \
                'image list and appliances available at the site (via AppDB)'
              ]
            end

            def options
              [
                [
                  :vo,
                  {
                    type: :string,
                    required: true,
                    desc: 'Virtual Organization name (used to select the appropriate VO-wide image list)'
                  }
                ],
                [
                  :token,
                  {
                    type: :string,
                    required: true,
                    desc: 'AppDB authentication token (used to access the VO-wide image list)'
                  }
                ],
                [
                  :warning_after,
                  {
                    type: :numeric,
                    default: 24,
                    desc: 'A number of hours after list publication when missing or outdated appliances raise WARNING'
                  }
                ],
                [
                  :critical_after,
                  {
                    type: :numeric,
                    default: 72,
                    desc: 'A number of hours after list publication when missing or outdated appliances raise CRITICAL'
                  }
                ]
              ]
            end

            def declaration
              'sync'
            end

            def runnable?
              true
            end
          end

          IMAGE_LIST_TEMPLATE = 'https://$$TOKEN$$:x-oauth-basic@vmcaster.appdb.egi.eu' \
                                '/store/vo/$$VO$$/image.list'.freeze

          def run(_args = [])
            @_results = { found: [], outdated: [], missing: [], expected: [] }

            Timeout.timeout(options[:timeout]) { check_vmc_sync }

            wrong = @_results[:missing] + @_results[:outdated]
            if wrong.any?
              if (@_last_update + options[:critical_after].hours) < Time.now
                puts "SYNC CRITICAL - Appliance(s) #{wrong.inspect} missing " \
                     "or outdated in #{vo.inspect} " \
                     "more than #{options[:critical_after]} hours after list publication [#{@_last_update}]"
                exit 2
              end

              if (@_last_update + options[:warning_after].hours) < Time.now
                puts "SYNC WARNING - Appliance(s) #{wrong.inspect} missing " \
                     "or outdated in #{vo.inspect} " \
                     "more than #{options[:warning_after]} hours after list publication [#{@_last_update}]"
                exit 1
              end
            end

            puts "SYNC OK - All appliances registered in #{vo.inspect} " \
                 "are available [#{@_results[:expected].count}]"
          rescue => ex
            puts "SYNC UNKNOWN - #{ex.message}"
            puts ex.backtrace if options[:debug]
            exit 3
          end

          private

          def check_vmc_sync
            vo_list.each do |hv_image|
              mpuri_versionless = versionless_mpuri(hv_image['ad:mpuri'])
              @_results[:expected] << mpuri_versionless

              matching = appliances_by_endpoint.detect do |appl|
                versionless_mpuri(appl['applicationEnvironmentRepository']) == mpuri_versionless
              end

              unless matching
                @_results[:missing] << mpuri_versionless
                next
              end

              unless hv_image['hv:version'] == matching['applicationEnvironmentAppVersion']
                @_results[:outdated] << mpuri_versionless
              end

              @_results[:found] << mpuri_versionless
            end
          end

          def vo_list
            return @_hv_images if @_hv_images

            list = JSON.parse(pkcs7_data)
            raise 'AppDB image list is empty or malformed' unless list && list['hv:imagelist']

            list = list['hv:imagelist']
            unless Time.parse(list['dc:date:expires']) > Time.now
              raise 'AppDB image list has expired'
            end
            raise "AppDB image list doesn't contain images" unless list['hv:images']
            @_last_update = Time.parse(list['dc:date:created'])

            @_hv_images = list['hv:images'].collect { |im| im['hv:image'] }
            @_hv_images.reject! { |im| im.blank? || im['ad:mpuri'].blank? }
            @_hv_images
          end

          def pkcs7_data
            content = OpenSSL::PKCS7.read_smime(retrieve_list)
            content.data
          end

          def retrieve_list
            response = HTTParty.get(list_url)
            raise "Could not get an image list from AppDB [HTTP #{response.code}]" unless response.success?

            response.parsed_response
          end

          def list_url
            IMAGE_LIST_TEMPLATE.gsub('$$TOKEN$$', options[:token]).gsub('$$VO$$', vo)
          end

          def normalize_mpuri(mpuri)
            mpuri.gsub(%r{/+$}, '')
          end

          def versionless_mpuri(mpuri)
            normalize_mpuri(mpuri).gsub(/:\d+$/, '')
          end
        end
      end
    end
  end
end
