import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["output", "panel", "status", "submit"]
  static values = { url: String }

  async submit(event) {
    event.preventDefault()
    if (this.submitTarget.disabled) return

    this.panelTarget.classList.remove("hidden")
    this.outputTarget.textContent = ""
    this.statusTarget.textContent = "Connecting..."
    this.submitTarget.disabled = true
    this.submitTarget.setAttribute("aria-busy", "true")

    try {
      const response = await fetch(this.urlValue, {
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

      this.statusTarget.textContent = "Streaming"
      await this.readStream(response.body)
    } catch (error) {
      this.statusTarget.textContent = "Failed"
      this.outputTarget.textContent += `\n${error.message}`
    } finally {
      this.submitTarget.disabled = false
      this.submitTarget.removeAttribute("aria-busy")
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
      this.outputTarget.textContent += event.text
      this.outputTarget.scrollTop = this.outputTarget.scrollHeight
    } else if (event.type === "started") {
      this.statusTarget.textContent = `Streaming (${event.request_id})`
    } else if (event.type === "complete") {
      this.statusTarget.textContent = "Complete"
    } else if (event.type === "error") {
      this.statusTarget.textContent = "Failed"
      this.outputTarget.textContent += `\n${event.message}`
    }
  }
}
