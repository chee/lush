const plugins = [
  {
    type: "patchwork:component",
    id: "apple-tray",
    name: "Apple",
    icon: "Apple",
    tags: ["system-tray"],
    async load() {
      return AppleTray;
    },
  },
];

function AppleTray(element) {
  const handler = globalThis.webkit?.messageHandlers?.appleTray;
  if (!handler) return;
  const style = document.createElement("style");
  style.textContent = `
    .apple-tray-button {
      border: none;
      background: none;
      cursor: pointer;
      font: inherit;
      font-size: 15px;
      line-height: 1;
      padding: 4px 6px;
      color: inherit;
      opacity: 0.75;
    }
    .apple-tray-button:hover { opacity: 1; }
  `;
  const button = document.createElement("button");
  button.className = "apple-tray-button";
  button.title = "Apple settings";
  button.textContent = "\u{F8FF}";
  button.addEventListener("click", () => handler.postMessage(null));
  element.append(style, button);
}

export { plugins };
