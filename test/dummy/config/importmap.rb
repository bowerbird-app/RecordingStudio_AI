# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "recording_studio_admin/screen_filters_base", to: "recording_studio_admin/controllers/screen_filters_controller.js", preload: false
pin "controllers/recording_studio_admin/async_widgets_controller", to: "recording_studio_admin/controllers/async_widgets_controller.js", preload: false

# Pin FlatPack controllers
pin_all_from FlatPack::Engine.root.join("app/javascript/flat_pack/controllers"), under: "controllers/flat_pack", to: "flat_pack/controllers", preload: false
pin "flat_pack/heroicons", to: "flat_pack/heroicons.js", preload: false
