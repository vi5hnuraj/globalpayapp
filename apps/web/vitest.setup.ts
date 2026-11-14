// Mock localStorage for jsdom 29 compatibility - fixes 3 pre-existing failures
// These failures are jsdom 29 localStorage SecurityError at about:blank
// The url option in environmentOptions should help, but this provides a fallback mock
let storedItems: Record<string, string> = {};

const ls: any = {
  getItem: (key: string) => {
    const item = storedItems[key];
    return item || null;
  },
  setItem: (key: string, value: string) => {
    storedItems[key] = value;
  },
  clear: () => {
    storedItems = {};
  },
  removeItem: (key: string) => {
    delete storedItems[key];
  },
  key: (i: number) => Object.keys(storedItems)[i] || null,
  length: Object.keys(storedItems).length,
};

Object.defineProperty(window, "localStorage", {
  value: ls,
  writable: true,
  configurable: true,
});
