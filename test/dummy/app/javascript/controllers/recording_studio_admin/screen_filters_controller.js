import ScreenFiltersController from "recording_studio_admin/screen_filters_base"

export default class extends ScreenFiltersController {
  queueDateRangeSubmit(event) {
    if (event.recordingStudioAdminDateSubmitQueued) {
      return
    }

    const applyButton = event.target.closest("[data-flat-pack-date-picker-command='apply']")
    if (!applyButton) {
      return
    }

    const form = this.dateRangeFormFor(applyButton)
    if (!form || form.id === "screen-filters-mobile-form") {
      return
    }

    event.recordingStudioAdminDateSubmitQueued = true
    this.showTableSkeletons()

    queueMicrotask(() => {
      this.syncDateRangePreset(form, applyButton)
      this.submitDateRangeForm(form)
    })
  }

  submitDateRangeForm(form) {
    const autoSubmit = this.application.getControllerForElementAndIdentifier(
      form,
      "flat-pack--auto-submit"
    )

    if (autoSubmit && typeof autoSubmit.queueSubmit === "function") {
      autoSubmit.queueSubmit()
      return
    }

    form.requestSubmit?.() || form.submit()
  }

  syncDateRangePreset(form, applyButton) {
    const picker = this.dateRangePickerFor(applyButton)
    const presetInput = picker?.parentElement?.querySelector("input[type='hidden'][name$='date_range_preset']")
    if (!picker || !presetInput) {
      return
    }

    const datePicker = this.application.getControllerForElementAndIdentifier(
      picker,
      "flat-pack--flatpack-date-picker"
    )
    presetInput.value = datePicker?.committedPresetKey || ""
  }

  dateRangeFormFor(applyButton) {
    const directForm = applyButton.closest("form")
    if (directForm) {
      return directForm
    }

    const panel = applyButton.closest("[role='dialog']")
    if (!panel?.id) {
      return null
    }

    const picker = this.dateRangePickerFor(applyButton)
    return picker?.closest("form")
  }

  dateRangePickerFor(applyButton) {
    const panel = applyButton.closest("[role='dialog']")
    if (!panel?.id) {
      return null
    }

    return document.querySelector(
      `[data-flat-pack--flatpack-date-picker-panel-id-value='${CSS.escape(panel.id)}']`
    )
  }
}
