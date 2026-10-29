import '@testing-library/jest-dom/vitest';

// jsdom has no matchMedia. Tests run at desktop width unless they set a viewport width.
export const viewport = { width: 1440 };

function matches(query: string): boolean {
  const max = /max-width:\s*(\d+)px/.exec(query);
  return max ? viewport.width <= Number(max[1]) : false;
}

window.matchMedia = (query: string) => ({
  matches: matches(query),
  media: query,
  onchange: null,
  addEventListener: () => {},
  removeEventListener: () => {},
  addListener: () => {},
  removeListener: () => {},
  dispatchEvent: () => false,
});
