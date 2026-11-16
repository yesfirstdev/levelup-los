import { describe, expect, it } from "vitest";
import { needsPasswordSetup, rootAuthCallback } from "./authEntry";

describe("root auth entry", () => {
  const hash = "#access_token=fake-access&refresh_token=fake-refresh&type=invite";
  it("routes a dashboard invite under the deployment base without exposing tokens in a query", () => {
    expect(rootAuthCallback({ pathname: "/levelup-los/", search: "", hash }, "/levelup-los/")).toBe(
      "/levelup-los/auth/callback" + hash,
    );
  });
  it("supports a root deployment and PKCE query", () => {
    expect(rootAuthCallback({ pathname: "/", search: "?code=fake-code", hash: "" }, "/")).toBe(
      "/auth/callback?code=fake-code",
    );
  });
  it("preserves auth errors for the callback error screen", () => {
    expect(
      rootAuthCallback({ pathname: "/app", search: "", hash: "#error=access_denied" }, "/app/"),
    ).toBe("/app/auth/callback#error=access_denied");
  });
  it("does not redirect ordinary root visits or arbitrary fragments", () => {
    for (const hash of ["", "#section", "#access_token=incomplete"]) {
      expect(
        rootAuthCallback(
          { pathname: "/app/", search: "?next=https://evil.example", hash },
          "/app/",
        ),
      ).toBeNull();
    }
  });
  it("does not loop at callback, intercept unrelated routes, or accept an external base", () => {
    for (const pathname of ["/app/auth/callback", "/app/people", "/other/"]) {
      expect(rootAuthCallback({ pathname, search: "", hash }, "/app/")).toBeNull();
    }
    expect(rootAuthCallback({ pathname: "/", search: "", hash }, "//evil.example/")).toBeNull();
  });
});

describe("password setup after email authentication", () => {
  it("recognizes dashboard invite, recovery and app reset links", () => {
    expect(needsPasswordSetup(undefined, "#type=invite")).toBe(true);
    expect(needsPasswordSetup(undefined, "#type=recovery")).toBe(true);
    expect(needsPasswordSetup("reset", "")).toBe(true);
  });
  it("does not ask ordinary magic-link sign-ins to reset passwords", () => {
    expect(needsPasswordSetup(undefined, "#type=magiclink")).toBe(false);
    expect(needsPasswordSetup(undefined, "")).toBe(false);
  });
});
