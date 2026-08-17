import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "form",
    "provider",
    "profile",
    "model",
    "parametersPanel",
    "temperatureField",
    "verbosityField",
    "maxOutputTokensField",
    "reasoningEffortField",
    "streamingField",
    "streaming",
    "webSearchField",
    "customToolsField",
    "useCustomTool",
    "toolPicker",
    "toolKey",
    "toolDescription",
    "attachmentField",
    "submit",
    "streamPanel",
    "streamStatus",
    "streamOutput"
  ]

  static values = {
    streamUrl: String,
    candidates: Object,
    definitions: Object,
    toolDescriptions: Object
  }

  connect() {
    this.refresh()
  }

  refresh() {
    this.refreshModels()
    this.refreshCapabilities()
    this.refreshToolDescription()
  }

  refreshModels() {
    if (!this.hasModelTarget || !this.hasProfileTarget) return

    const profile = this.profileTarget.value
    const provider = this.hasProviderTarget ? this.providerTarget.value : ""
    let candidates = this.candidatesValue[profile] || []
    if (provider && provider !== "auto") {
      candidates = candidates.filter((candidate) => candidate.provider === provider)
    }

    const previous = this.modelTarget.value
    this.modelTarget.innerHTML = ""

    candidates.forEach((candidate, index) => {
      const option = document.createElement("option")
      option.value = candidate.value
      option.textContent = candidate.label
      if (candidate.value === previous || (!previous && index === 0)) {
        option.selected = true
      }
      this.modelTarget.appendChild(option)
    })

    if (!this.modelTarget.value && candidates[0]) {
      this.modelTarget.value = candidates[0].value
    }
  }

  refreshCapabilities() {
    const definition = this.selectedDefinition()
    const show = (target, visible) => {
      if (!this[`has${this.capitalize(target)}Target`]) return
      this[`${target}Target`].classList.toggle("hidden", !visible)
    }

    const parameters = definition?.parameters || {}
    const hasParameters = Object.values(parameters).some((spec) => spec?.supported)
    show("parametersPanel", hasParameters)
    show("temperatureField", parameters.temperature?.supported === true)
    show("verbosityField", parameters.verbosity?.supported === true)
    show("maxOutputTokensField", parameters.max_output_tokens?.supported === true)
    show("reasoningEffortField", parameters.reasoning_effort?.supported === true)

    show("streamingField", definition?.delivery?.streaming === true)
    show("webSearchField", Array.isArray(definition?.tools) && definition.tools.includes("web_search"))
    show("customToolsField", Array.isArray(definition?.tools) && definition.tools.includes("custom_tools"))
    show(
      "attachmentField",
      Array.isArray(definition?.modalities?.input) &&
        (definition.modalities.input.includes("image") || definition.modalities.input.includes("file"))
    )

    this.refreshToolPickerVisibility()
  }

  refreshToolDescription() {
    this.refreshToolPickerVisibility()
    if (!this.hasToolDescriptionTarget || !this.hasToolKeyTarget) return

    const key = this.toolKeyTarget.value
    this.toolDescriptionTarget.textContent = this.toolDescriptionsValue[key] || ""
  }

  refreshToolPickerVisibility() {
    if (!this.hasToolPickerTarget) return
    const enabled = this.hasUseCustomToolTarget && this.useCustomToolTarget.checked
    this.toolPickerTarget.classList.toggle("hidden", !enabled)
  }

  async submit(event) {
    if (!this.streamingEnabled()) return

    event.preventDefault()
    if (this.hasSubmitTarget && this.submitTarget.disabled) return

    if (this.hasStreamPanelTarget) this.streamPanelTarget.classList.remove("hidden")
    if (this.hasStreamOutputTarget) this.streamOutputTarget.textContent = ""
    if (this.hasStreamStatusTarget) this.streamStatusTarget.textContent = "Connecting..."
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      this.submitTarget.setAttribute("aria-busy", "true")
    }

    try {
      const response = await fetch(this.streamUrlValue, {
        method: "POST",
        headers: {
          Accept: "text/event-stream",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: new FormData(event.currentTarget)
      })

      if (!response.ok || !response.body) {
        const message = (await response.text()).trim()
        throw new Error(message || `Streaming request failed (${response.status})`)
      }

      if (this.hasStreamStatusTarget) this.streamStatusTarget.textContent = "Streaming"
      await this.readStream(response.body)
    } catch (error) {
      if (this.hasStreamStatusTarget) this.streamStatusTarget.textContent = "Failed"
      if (this.hasStreamOutputTarget) this.streamOutputTarget.textContent += `\n${error.message}`
    } finally {
      if (this.hasSubmitTarget) {
        this.submitTarget.disabled = false
        this.submitTarget.removeAttribute("aria-busy")
      }
    }
  }

  async readStream(body) {
    const reader = body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""

    while (true) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done })

      const messages = buffer.split("\n\n")
      buffer = messages.pop()
      messages.forEach((message) => this.handleMessage(message))

      if (done) break
    }
  }

  handleMessage(message) {
    const data = message
      .split("\n")
      .find((line) => line.startsWith("data: "))
      ?.slice(6)
    if (!data) return

    const event = JSON.parse(data)
    if (event.type === "delta") {
      if (this.hasStreamOutputTarget) {
        this.streamOutputTarget.textContent += event.text
        this.streamOutputTarget.scrollTop = this.streamOutputTarget.scrollHeight
      }
    } else if (event.type === "started" && this.hasStreamStatusTarget) {
      this.streamStatusTarget.textContent = `Streaming (${event.request_id})`
    } else if (event.type === "complete" && this.hasStreamStatusTarget) {
      this.streamStatusTarget.textContent = "Complete"
    } else if (event.type === "error") {
      if (this.hasStreamStatusTarget) this.streamStatusTarget.textContent = "Failed"
      if (this.hasStreamOutputTarget) this.streamOutputTarget.textContent += `\n${event.message}`
    }
  }

  selectedDefinition() {
    if (!this.hasModelTarget) return null
    return this.definitionsValue[this.modelTarget.value] || null
  }

  streamingEnabled() {
    return this.hasStreamingTarget && this.streamingTarget.checked && this.hasStreamingFieldTarget &&
      !this.streamingFieldTarget.classList.contains("hidden")
  }

  capitalize(value) {
    return value.charAt(0).toUpperCase() + value.slice(1)
  }
}
