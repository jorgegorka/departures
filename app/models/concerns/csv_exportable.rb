module CsvExportable
  extend ActiveSupport::Concern

  class_methods do
    private
      # Spreadsheet apps evaluate cells starting with = + - @ (or tab/CR) as
      # formulas, so prefix them with a quote to neutralize CSV injection.
      def csv_safe(value)
        text = value.to_s
        if text.match?(/\A[=+\-@\t\r]/)
          "'#{text}"
        else
          text
        end
      end
  end
end
