# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAICreditPricesScreen < RecordingStudioAdmin::Screen
    key "credit_prices"
    icon :banknotes
    title { Copy.t("admin.screens.credit_prices.title") }
    subtitle { Copy.t("admin.screens.credit_prices.subtitle") }

    query do |_context|
      RecordingStudioAI::Credits.price_rows(RecordingStudioAI.configuration)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :provider,
             title: Copy.t("admin.screens.credit_prices.columns.provider"),
             header_tooltip: Copy.t("admin.screens.credit_prices.tooltips.provider"),
             value: lambda { |row, _context|
               if row.fetch(:provider) == "any"
                 Copy.t("admin.screens.credit_prices.any_provider")
               else
                 row.fetch(:provider)
               end
             }
      column :model,
             title: Copy.t("admin.screens.credit_prices.columns.model"),
             header_tooltip: Copy.t("admin.screens.credit_prices.tooltips.model"),
             value: lambda { |row, _context|
               row.fetch(:model) == "any" ? Copy.t("admin.screens.credit_prices.any_model") : row.fetch(:model)
             }
      column :prices,
             title: Copy.t("admin.screens.credit_prices.columns.prices"),
             header_tooltip: Copy.t("admin.screens.credit_prices.tooltips.prices"),
             value: lambda { |row, _context|
               row.fetch(:prices).map do |price|
                 if price.fetch(:per) == 1
                   Copy.t(
                     "admin.screens.credit_prices.per_use",
                     kind: price.fetch(:kind), credits: price.fetch(:credits)
                   )
                 else
                   Copy.t(
                     "admin.screens.credit_prices.per_many",
                     kind: price.fetch(:kind), credits: price.fetch(:credits), per: price.fetch(:per)
                   )
                 end
               end.join(", ")
             }
      column :notice,
             title: Copy.t("admin.screens.credit_prices.columns.notice"),
             header_tooltip: Copy.t("admin.screens.credit_prices.tooltips.notice"),
             value: lambda { |row, _context|
               notice = row[:notice]
               notice ? Copy.t("admin.screens.credit_prices.notices.#{notice}") : ""
             }
    end
  end
end
