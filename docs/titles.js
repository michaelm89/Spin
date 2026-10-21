// Same rules as the Mac app (PlaybackState.cleanTitle): drop release clutter like
// remasters, edits, versions and featured artists, but keep real subtitles.
const CLUTTER = /remaster|re-?master|edit\b|version|\bmix\b|remix|\bmono\b|stereo|feat\.?|\bft\.|featuring|\bwith\b|single|radio|bonus|deluxe|anniversary|re-?recorded|explicit|\bclean\b/i;
const TRAILING = /\s+((\d{4}\s+)?(digital(ly)?\s+)?(remaster(ed)?|re-?master|mono|stereo|radio edit|single edit|single version|album version)(\s+(version|\d{4}))*|(feat\.?|ft\.|featuring)\s+.*)$/i;

export function cleanTitle(title) {
  let t = title;

  // " - Remastered 2011": cut a spaced-dash suffix only if it's clutter.
  const dash = /\s+[-–—]\s+/.exec(t);
  if (dash && dash.index > 0 && CLUTTER.test(t.slice(dash.index + dash[0].length))) {
    t = t.slice(0, dash.index);
  }

  // "(Single Edit)", "[2012 Remaster]", "(feat. X)" go; "(A Man After Midnight)" stays.
  t = t.replace(/\s*[([]([^)\]]*)[)\]]/g, (whole, inner, offset) =>
    offset > 0 && CLUTTER.test(inner) ? "" : whole);

  // Loose clutter at the end: "2022 Remaster", "Remastered 2009", "Radio Edit".
  for (let m; (m = TRAILING.exec(t)); ) t = t.slice(0, m.index);

  t = t.replace(/\s{2,}/g, " ").replace(/^[\s,–—-]+|[\s,–—-]+$/g, "");
  return t || title;
}

// Spotify serves each cover at several sizes; key albums by the image id so they match.
export function artworkID(url) {
  const i = url ? url.indexOf("ab67616d") : -1;
  return i >= 0 && url.length - i >= 56 ? url.slice(i + 16, i + 56) : url;
}

export function artworkURL(id, size = 640) {
  if (!id || id.startsWith("http")) return id;
  const prefix = { 640: "ab67616d0000b273", 300: "ab67616d00001e02" }[size] ?? "ab67616d0000b273";
  return `https://i.scdn.co/image/${prefix}${id}`;
}
