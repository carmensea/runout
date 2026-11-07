import { cleanup, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { connectedApi } from "../../test/fixtures";
import { renderApp } from "../../test/renderApp";
import { viewport } from "../../test/setup";

// The period and comparison controls appear only where the period changes the page: the Overview,
// the Time Machine and the genre pages. Settings, the loved library, the welcome page and the
// placeholders keep search and the account menu and nothing else.
describe("Period controls, only where they are useful", () => {
  afterEach(() => {
    cleanup();
    viewport.width = 1440;
  });

  it("shows them on the Overview, on desktop", async () => {
    renderApp(connectedApi(), "/overview?period=all");
    expect(
      await screen.findByRole("radiogroup", { name: "Period type" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /^Compare/ }),
    ).toBeInTheDocument();
  });

  it("hides them on Settings and keeps search, on desktop", async () => {
    renderApp(connectedApi(), "/settings");
    expect(
      await screen.findByRole("heading", { name: "Settings" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("radiogroup", { name: "Period type" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /^Compare/ }),
    ).not.toBeInTheDocument();
    expect(screen.getByPlaceholderText(/Search artists/)).toBeInTheDocument();
  });

  it("hides them on the loved library, which ignores the period", async () => {
    renderApp(connectedApi(), "/loved");
    expect(
      await screen.findByRole("heading", { name: /Loved/ }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("radiogroup", { name: "Period type" }),
    ).not.toBeInTheDocument();
  });

  it("shows the period button on the Overview, on a phone", async () => {
    viewport.width = 375;
    renderApp(connectedApi(), "/overview?period=all");
    expect(
      await screen.findByRole("button", { name: /^Period:/ }),
    ).toBeInTheDocument();
  });

  it("hides the period button and the comparison on Settings, on a phone", async () => {
    viewport.width = 375;
    renderApp(connectedApi(), "/settings");
    expect(
      await screen.findByRole("heading", { name: "Settings" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /^Period:/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", {
        name: "Compare with the previous period",
      }),
    ).not.toBeInTheDocument();
  });
});
