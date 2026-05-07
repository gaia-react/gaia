/**
 * `[[wikilink]]` extractor for wiki page bodies.
 *
 * Obsidian-flavored wikilinks support a `|` alias separator and the optional
 * `#section` anchor:
 *
 *   [[Wiki Sync]]
 *   [[Wiki Sync|`/wiki-sync`]]
 *   [[Wiki Sync#Step 3]]
 *   [[Wiki Sync#Step 3|step three]]
 *
 * The target — the slug we count for inbound/outbound — is the part before
 * `#` and `|`, trimmed.
 */
const WIKILINK_PATTERN = /\[\[([^\][]+)\]\]/gu;

/**
 * Return every wikilink target referenced in `body`. Targets are normalized
 * by stripping `#anchor`, `|alias`, and surrounding whitespace. Duplicates
 * are preserved — callers that want unique targets should `new Set(...)`.
 */
export const extractWikilinks = (body: string): string[] => {
  const targets: string[] = [];
  let match: RegExpExecArray | null = WIKILINK_PATTERN.exec(body);

  while (match !== null) {
    const raw = (match[1] as string).trim();
    const aliasIndex = raw.indexOf('|');
    const withoutAlias = aliasIndex === -1 ? raw : raw.slice(0, aliasIndex);
    const anchorIndex = withoutAlias.indexOf('#');
    const target = (
      anchorIndex === -1 ? withoutAlias : withoutAlias.slice(0, anchorIndex)
    ).trim();

    if (target.length > 0) targets.push(target);
    match = WIKILINK_PATTERN.exec(body);
  }

  return targets;
};
