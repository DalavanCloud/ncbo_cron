require 'logger'
require 'benchmark'

module NcboCron
  module Models
    class OntologiesReport

      ERROR_CODES = {
          summaryOnly:                              "Ontology is summary-only",
          flat:                                     "This ontology is designated as FLAT",
          errSummaryOnlyWithSubmissions:            "Ontology has submissions but it is set to summary-only",
          errNoSubmissions:                         "Ontology has no submissions",
          errNoReadySubmission:                     "Ontology has no submissions in a ready state",
          errNoLatestReadySubmission:               lambda { |n| "The latest submission is not ready and is ahead of the latest ready by #{n} revision#{n > 1 ? 's' : ''}" },
          errNoClassesLatestReadySubmission:        "The latest ready submission has no classes",
          errNoRootsLatestReadySubmission:          "The latest ready submission has no roots",
          errNoMetricsLatestReadySubmission:        "The latest ready submission has no metrics",
          errIncorrectMetricsLatestReadySubmission: "The latest ready submission has incorrect metrics",
          errNoAnnotator:                           lambda { |data| "Annotator - #{data[0] > 0 ? 'FEW' : 'NO'} results for: #{data[1]}" },
          errNoSearch:                              lambda { |data| "Search - #{data[0] > 0 ? 'FEW' : 'NO'} results for: #{data[1]}" },
          errRunningReport:                         lambda { |data| "Error while running report on component #{data[0]}: #{data[1]}: #{data[2]}" },
          errErrorStatus:                           [],
          errMissingStatus:                         []
      }

      def initialize(logger, saveto)
        @logger = logger
        @saveto = saveto
        @stop_words = Annotator.settings.stop_words_default_list
      end

      def run
        @logger.info("Running ontologies report...\n")
        ontologies = LinkedData::Models::Ontology.where.include(:acronym).all
        # ontologies_to_indclude = ["AERO", "SBO", "EHDAA", "CCO", "ONLIRA", "VT", "ZEA", "SMASH", "PLIO", "OGI", "CO", "NCIT", "GO"]
        # ontologies_to_indclude = ["DCM", "D1-CARBON-FLUX", "STUFF"]
        # ontologies_to_indclude = ["ADAR", "PR", "PORO", "PROV", "PSIMOD"]
        # ontologies.select! { |ont| ontologies_to_indclude.include?(ont.acronym) }
        report = {ontologies: {}, date_generated: nil}
        count = 0
        ontologies.each do |ont|
          count += 1
          @logger.info("Processing report for #{ont.acronym} - #{count} of #{ontologies.length} ontologies."); @logger.flush
          time = Benchmark.realtime do
            report[:ontologies][ont.acronym] = sanity_report(ont)
          end
          @logger.info("Finished report for #{ont.acronym} in #{time} sec."); @logger.flush
        end

        tm = Time.new
        report[:date_generated] = tm.strftime("%m/%d/%Y %I:%M%p")
        File.open(@saveto, 'w') { |file| file.write(JSON.pretty_generate(report)) }
        @logger.info("Finished generating ontologies report. Wrote report data to #{@saveto}.\n"); @logger.flush
      end

      def sanity_report(ont)
        report = {problem: false, logFilePath: ''}
        ont.bring_remaining()
        ont.bring(:submissions)
        submissions = ont.submissions

        # first see if is summary only and if it has submissions
        if ont.summaryOnly
          if !submissions.nil? && submissions.length > 0
            add_error_code(report, :errSummaryOnlyWithSubmissions)
          else
            add_error_code(report, :summaryOnly)
          end
          return report
        end

        # check if latest submission is the one ready
        latest_any = ont.latest_submission(status: :any)
        if latest_any.nil?
          # no submissions, cannot continue
          add_error_code(report, :errNoSubmissions)
          return report
        end

        # path to most recent log file
        log_file_path = log_file(ont.acronym, latest_any.submissionId.to_s)
        report[:logFilePath] = log_file_path unless log_file_path.empty?

        latest_ready = ont.latest_submission
        if latest_ready.nil?
          # no ready submission exists, cannot continue
          add_error_code(report, :errNoReadySubmission)
          # add error statuses from the latest non-ready submission
          latest_any.submissionStatus.each { |st| add_error_code(report, :errErrorStatus, st.get_code_from_id) if st.error? }
          return report
        end

        # submission that's ready is not the latest one
        if latest_any.id.to_s != latest_ready.id.to_s
          sub_count = 0
          latest_submission_id = latest_ready.submissionId.to_i
          ont.submissions.each { |sub| sub_count += 1 if sub.submissionId.to_i > latest_submission_id }
          add_error_code(report, :errNoLatestReadySubmission, sub_count)
        end

        # rest of the tests run for latest_ready
        sub = latest_ready
        sub.bring_remaining()
        sub.ontology.bring_remaining()
        sub.bring(:metrics)

        # add error statuses
        sub.submissionStatus.each { |st| add_error_code(report, :errErrorStatus, st.get_code_from_id) if st.error? }

        # add missing statuses
        statuses = LinkedData::Models::SubmissionStatus.where.all
        statuses.select! { |st| !st.error? }
        statuses.select! { |st| st.id.to_s["DIFF"].nil? }
        statuses.select! { |st| st.id.to_s["ARCHIVED"].nil? }
        statuses.select! { |st| st.id.to_s["RDF_LABELS"].nil? }

        statuses.each do |ok|
          found = false
          sub.submissionStatus.each do |st|
            if st == ok
              found = true
              break
            end
          end
          add_error_code(report, :errMissingStatus, ok.get_code_from_id) unless found
        end

        # check whether ontology has been designated as "flat" or root classes exist
        if sub.ontology.flat
          add_error_code(report, :flat)
        else
          begin
            add_error_code(report, :errNoRootsLatestSubmission) unless sub.roots().length > 0
          rescue Exception => e
            add_error_code(report, :errNoRootsLatestSubmission)
            add_error_code(report, :errRunningReport, ["sub.roots()", e.class, e.message])
          end
        end

        # check if metrics has been generated
        metrics = sub.metrics
        if metrics.nil?
          add_error_code(report, :errNoMetricsLatestSubmission)
        else
          metrics.bring_remaining()
          if metrics.classes + metrics.properties < 10
            add_error_code(report, :errIncorrectMetricsLatestSubmission)
          end
        end

        # check if classes exist
        good_classes = good_classes(sub)

        if good_classes.empty?
          add_error_code(report, :errNoClassesLatestSubmission)
        else
          search_text = good_classes.join(" | ")
          # check for Annotator calls
          ann = Annotator::Models::NcboAnnotator.new(@logger)
          ann_response = ann.annotate(search_text, { ontologies: [ont.acronym] })
          add_error_code(report, :errNoAnnotator, [ann_response.length, search_text]) if ann_response.length < good_classes.length

          # check for Search calls
          resp = LinkedData::Models::Class.search(solr_escape(search_text), query_params(ont.acronym))
          add_error_code(report, :errNoSearch, [resp["response"]["numFound"], search_text]) if resp["response"]["numFound"] < good_classes.length
        end

        return report
      end

      def good_classes(submission)
        page_num = 1
        page_size = 1000
        classes_size = 10
        good_classes = Array.new

        paging = LinkedData::Models::Class.in(submission).include(:prefLabel, :synonym).page(page_num, page_size)

        begin
          page_classes = nil

          begin
            page_classes = paging.page(page_num, page_size).all
          rescue Exception =>  e
            # some obscure error that happens intermittently
            @logger.error("#{e.class}: #{e.message}")
            @logger.error("Sub: #{submission.id}")
            throw e
          end

          break if page_classes.empty?

          page_classes.each do |cls|
            prefLabel = nil

            begin
              prefLabel = cls.prefLabel
            rescue Goo::Base::AttributeNotLoaded =>  e
              next
            end

            # Skip classes with no prefLabel, short prefLabel, b-nodes, or stop-words
            next if prefLabel.nil? || prefLabel.length < 3 ||
                cls.id.to_s.include?(".well-known/genid") || @stop_words.include?(prefLabel.upcase)

            # store good prefLabel
            good_classes << prefLabel
            break if good_classes.length === classes_size
          end

          page_num = (good_classes.length === classes_size || !page_classes.next?) ? nil : page_num + 1
        end while !page_num.nil?

        good_classes
      end

      def log_file(acronym, submission_id)
        log_file_path = ''

        begin
          ont_repo_path = Dir.open("#{LinkedData.settings.repository_folder}/#{acronym}/#{submission_id}")
          log_file_path = Dir.glob(File.join(ont_repo_path, '*.log')).max_by {|f| File.mtime(f)}
        rescue Exception => e
          # no log file or dir exists
        end
        log_file_path ||= ''
      end

      def solr_escape(text)
        RSolr.solr_escape(text).gsub(/\s+/,"\\ ")
      end

      def add_error_code(report, code, data=nil)
        report[:problem] = false unless report.has_key? :problem
        if ERROR_CODES.has_key? code
          if ERROR_CODES[code].kind_of?(Array)
            unless data.nil?
              report[code] = [] unless report.has_key? code
              report[code] << data
            end
          elsif ERROR_CODES[code].is_a? (Proc)
            unless data.nil?
              report[code] = ERROR_CODES[code].call(data)
            end
          else
            report[code] = ERROR_CODES[code]
          end
          report[:problem] = true if code.to_s.start_with? "err"
        end
      end

      def query_params(acronym)
        return {
          "defType" => "edismax",
          "stopwords" => "true",
          "lowercaseOperators" => "true",
          "fl" => "*,score",
          "hl" => "on",
          "hl.simple.pre" => "<em>",
          "hl.simple.post" => "</em>",
          "qf" => "resource_id^100 prefLabelExact^90 prefLabel^70 synonymExact^50 synonym^10 notation cui semanticType",
          "hl.fl" => "resource_id prefLabelExact prefLabel synonymExact synonym notation cui semanticType",
          "fq" => "submissionAcronym:\"#{acronym}\" AND obsolete:false",
          "page" => 1,
          "pagesize" => 50,
          "start" => 0,
          "rows" => 50
        }
      end

    end
  end
end

# require 'ontologies_linked_data'
# require 'goo'
# require 'ncbo_annotator'
# require 'ncbo_cron/config'
# require_relative '../../config/config'
#
# ontologies_report_path = File.join("logs", "ontologies-report.log")
# ontologies_report_logger = Logger.new(ontologies_report_path)
# save_report_path = "../test/reports/ontologies_report.json"
# NcboCron::Models::OntologiesReport.new(ontologies_report_logger, save_report_path).run
# ./bin/ncbo_cron --disable-processing true --disable-pull true --disable-flush true --disable-warmq true --disable-ontology-analytics true --ontologies-report '22 * * * *'