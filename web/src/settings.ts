import type { PatchworkApi } from "./patchwork-api";
import type { DocLink } from "./types";

type Property = {
  key: string;
  label: string;
  type: string;
  value: string | null;
};

const STYLE = `
#patchwork-settings {
  position: fixed; inset: 0; z-index: 2147483000;
  display: flex; align-items: flex-start; justify-content: center;
  background: rgba(0, 0, 0, 0.28);
  font-family: -apple-system, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  --panel: #ececec; --box: #ffffff; --text: #1d1d1f; --muted: #86868b;
  --hairline: rgba(0, 0, 0, 0.08); --accent: #0071e3;
}
@media (prefers-color-scheme: dark) {
  #patchwork-settings {
    --panel: #282828; --box: #3a3a3c; --text: #f5f5f7; --muted: #98989d;
    --hairline: rgba(255, 255, 255, 0.1);
  }
}
#patchwork-settings .pw-settings {
  margin-top: 12vh; width: 560px; max-width: calc(100vw - 48px);
  background: var(--panel); color: var(--text);
  border-radius: 12px; overflow: hidden;
  box-shadow: 0 22px 70px rgba(0, 0, 0, 0.45), 0 0 0 0.5px var(--hairline);
}
#patchwork-settings .pw-settings__head {
  display: flex; align-items: center; justify-content: space-between;
  padding: 14px 18px 10px;
}
#patchwork-settings .pw-settings__title { font-size: 15px; font-weight: 600; }
#patchwork-settings .pw-settings__close {
  border: none; background: transparent; color: var(--muted);
  font-size: 16px; cursor: pointer; padding: 2px 6px; border-radius: 6px;
}
#patchwork-settings .pw-settings__close:hover { background: var(--hairline); }
#patchwork-settings .pw-settings__body { padding: 4px 18px 16px; }
#patchwork-settings .pw-settings__group {
  background: var(--box); border-radius: 10px;
  box-shadow: 0 0 0 0.5px var(--hairline);
}
#patchwork-settings .pw-settings__row {
  display: flex; align-items: center; justify-content: space-between;
  gap: 16px; padding: 10px 14px; min-height: 24px;
}
#patchwork-settings .pw-settings__row + .pw-settings__row {
  border-top: 0.5px solid var(--hairline);
}
#patchwork-settings .pw-settings__label { font-size: 13px; }
#patchwork-settings .pw-settings__control select {
  max-width: 260px; font-size: 13px;
}
#patchwork-settings .pw-settings__foot {
  padding: 10px 18px 14px; display: flex; justify-content: space-between;
  align-items: center; gap: 12px;
}
#patchwork-settings .pw-settings__doc {
  font-family: ui-monospace, monospace; font-size: 10px; color: var(--muted);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
`;

function patchworkApi(): PatchworkApi {
  return window.Patchwork as PatchworkApi;
}

async function openSettings(): Promise<void> {
  document.getElementById("patchwork-settings")?.remove();
  const api = patchworkApi();
  const [properties, folders] = await Promise.all([
    api.appleConfigProperties() as Promise<Property[]>,
    api.listRootFolders(),
  ]);

  const overlay = document.createElement("div");
  overlay.id = "patchwork-settings";
  const style = document.createElement("style");
  style.textContent = STYLE;
  overlay.appendChild(style);

  const panel = document.createElement("div");
  panel.className = "pw-settings";
  overlay.appendChild(panel);

  const head = document.createElement("div");
  head.className = "pw-settings__head";
  const title = document.createElement("div");
  title.className = "pw-settings__title";
  title.textContent = "Patchwork Settings";
  const close = document.createElement("button");
  close.className = "pw-settings__close";
  close.textContent = "✕";
  close.onclick = () => overlay.remove();
  head.append(title, close);
  panel.appendChild(head);

  const body = document.createElement("div");
  body.className = "pw-settings__body";
  const group = document.createElement("div");
  group.className = "pw-settings__group";
  body.appendChild(group);
  panel.appendChild(body);

  for (const property of properties) {
    group.appendChild(row(property, folders));
  }

  const foot = document.createElement("div");
  foot.className = "pw-settings__foot";
  const doc = document.createElement("div");
  doc.className = "pw-settings__doc";
  doc.textContent = api.account?.doc()?.tools?.apple ?? "";
  foot.appendChild(doc);
  panel.appendChild(foot);

  overlay.addEventListener("mousedown", (event) => {
    if (event.target === overlay) overlay.remove();
  });
  const onKey = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      overlay.remove();
      window.removeEventListener("keydown", onKey, true);
    }
  };
  window.addEventListener("keydown", onKey, true);

  document.body.appendChild(overlay);
}

function row(property: Property, folders: DocLink[]): HTMLElement {
  const el = document.createElement("div");
  el.className = "pw-settings__row";
  const label = document.createElement("div");
  label.className = "pw-settings__label";
  label.textContent = property.label;
  const control = document.createElement("div");
  control.className = "pw-settings__control";
  el.append(label, control);

  const select = document.createElement("select");
  const none = new Option("None", "");
  select.add(none);
  for (const folder of folders) {
    select.add(new Option(folder.name, folder.url));
  }
  if (
    property.value &&
    !folders.some((folder) => folder.url === property.value)
  ) {
    select.add(new Option(`Other (${property.value})`, property.value));
  }
  select.value = property.value ?? "";
  select.onchange = () => {
    void patchworkApi().setAppleConfigValue(
      property.key,
      select.value === "" ? null : select.value,
    );
  };
  control.appendChild(select);
  return el;
}

export function installSettings(): void {
  window.__patchworkOpenSettings = () => void openSettings();
}
