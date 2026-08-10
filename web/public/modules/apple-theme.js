const plugins = [
  {
    type: "patchwork:theme",
    id: "apple-light",
    name: "Apple Light",
    style: new URL("./apple-theme.css", import.meta.url).href,
    async load() {
      return {};
    },
  },
  {
    type: "patchwork:theme",
    id: "apple-dark",
    name: "Apple Dark",
    style: new URL("./apple-theme.css", import.meta.url).href,
    async load() {
      return {};
    },
  },
];

export { plugins };
