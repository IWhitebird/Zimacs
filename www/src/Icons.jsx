/* Platform marks drawn on a 16x16 pixel grid, so they sit next to the pixel
   logo rather than looking like a stock icon set. Knocked-out detail uses the
   card colour, which is why these want a --raised background behind them.
   macOS gets a laptop rather than a fruit: the label says which OS it is, and
   this way no company's logo is redrawn. */

export function Linux(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      {/* head, then body, then feet */}
      <path d="M6 1h4v1H6zM5 2h6v4H5zM4 6h8v2H4zM3 8h10v5H3zM4 13h3v2H4zM9 13h3v2H9z" />
      {/* eyes and beak knocked out */}
      <path fill="var(--raised)" d="M6 3h1v2H6zM9 3h1v2H9zM7 5h2v1H7z" />
      {/* belly */}
      <path fill="var(--raised)" d="M6 9h4v4H6z" />
    </svg>
  );
}

export function Windows(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      <path d="M1 3h6v6H1zM9 2h6v7H9zM1 10h6v5H1zM9 10h6v6H9z" />
    </svg>
  );
}

export function Web(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      {/* ring */}
      <path d="M6 1h4v1H6zM4 2h2v1H4zM10 2h2v1h-2zM3 3h1v1H3zM12 3h1v1h-1zM2 4h1v2H2zM13 4h1v2h-1zM1 6h1v4H1zM14 6h1v4h-1zM2 10h1v2H2zM13 10h1v2h-1zM3 12h1v1H3zM12 12h1v1h-1zM4 13h2v1H4zM10 13h2v1h-2zM6 14h4v1H6z" />
      {/* meridian and equator */}
      <path d="M7 2h2v12H7zM2 7h12v2H2z" />
    </svg>
  );
}

export function Laptop(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      {/* lid, screen knocked out, then the base */}
      <path d="M3 2h10v9H3z" />
      <path fill="var(--raised)" d="M4 3h8v7H4z" />
      <path d="M1 12h14v2H1z" />
    </svg>
  );
}

export function GitHub(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      <path d="M8 0a8 8 0 0 0-2.53 15.59c.4.07.55-.17.55-.38l-.01-1.34c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.72 1.23 1.88.87 2.34.67.07-.52.28-.87.5-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48l-.01 2.2c0 .21.14.46.55.38A8 8 0 0 0 8 0z" />
    </svg>
  );
}

/* The official Zig mark, unmodified, from github.com/ziglang/logo.
   Licensed CC BY-SA 4.0 by the Zig Software Foundation. It keeps its own
   orange rather than taking currentColor, because that is the logo. */
export function Zig(props) {
  return (
    <svg viewBox="0 0 153 140" fill="#f7a41d" {...props}>
      <polygon points="46,22 28,44 19,30" />
      <polygon
        points="46,22 33,33 28,44 22,44 22,95 31,95 20,100 12,117 0,117 0,22"
        shapeRendering="crispEdges"
      />
      <polygon points="31,95 12,117 4,106" />
      <polygon points="56,22 62,36 37,44" />
      <polygon
        points="56,22 111,22 111,44 37,44 56,32"
        shapeRendering="crispEdges"
      />
      <polygon points="116,95 97,117 90,104" />
      <polygon
        points="116,95 100,104 97,117 42,117 42,95"
        shapeRendering="crispEdges"
      />
      <polygon points="150,0 52,117 3,140 101,22" />
      <polygon points="141,22 140,40 122,45" />
      <polygon
        points="153,22 153,117 106,117 120,105 125,95 131,95 131,45 122,45 132,36 141,22"
        shapeRendering="crispEdges"
      />
      <polygon points="125,95 130,110 106,117" />
    </svg>
  );
}

export function Scale(props) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" {...props}>
      <path d="M7 1h2v14H7zM3 3h10v1H3zM4 14h8v1H4zM1 9h5v1H1zM10 9h5v1h-5zM3 5h1v4H3zM12 5h1v4h-1z" />
    </svg>
  );
}
