/** Dashboard emails may land at the site root instead of the callback route. */
export function rootAuthCallback(
  location: Pick<Location, "pathname" | "search" | "hash">,
  base: string,
): string | null {
  // Build-time base paths are local paths, never an external redirect target.
  if (!base.startsWith("/") || base.startsWith("//")) return null;
  const root = base.replace(/\/$/, "");
  if (location.pathname !== root && location.pathname !== root + "/") return null;
  const query = new URLSearchParams(location.search);
  const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
  const hasSession = Boolean(hash.get("access_token") && hash.get("refresh_token"));
  const hasError = Boolean(hash.get("error") || hash.get("error_code") || query.get("error"));
  if (!hasSession && !hasError && !query.get("code")) return null;
  // Preserve the fragment without decoding it or putting its secrets in the query.
  return root + "/auth/callback" + location.search + location.hash;
}

export function needsPasswordSetup(next: string | undefined, hash: string): boolean {
  const type = new URLSearchParams(hash.replace(/^#/, "")).get("type");
  return next === "reset" || type === "invite" || type === "recovery";
}
