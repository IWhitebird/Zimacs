const REPO = "https://github.com/IWhitebird/Zimacs";

const FEATURES = [
  "Piece-tree text storage, so edits stay fast in large files",
  "Tabs, undo and redo, selection by keyboard and mouse",
  "Find, go to line, and a file browser drawn in the editor",
  "Session restore — unsaved work comes back next time",
  "Optional line wrapping, UTF-8 throughout, configurable colours",
  "One binary. No toolkit to install, no runtime, font included",
];

const BUILD = `git clone ${REPO}
cd Zimacs
zig build run`;

/* The halftone sun. Three rings of dots over a solid core, drawn in CSS. */
function Sun() {
  return (
    <div className="sun" aria-hidden="true">
      <i className="b1" />
      <i className="b2" />
      <i className="b3" />
    </div>
  );
}

function Hero() {
  return (
    <header className="hero">
      <Sun />
      <img src="/Zimacs/logo.png" alt="" width="108" height="108" />
      <h1 className="wordmark">ZIMACS</h1>
      <p className="tagline">
        A small, fast, self-contained text editor written in Zig.
      </p>
      <div className="actions">
        <a className="button primary" href={`${REPO}/releases/latest`}>
          Download
        </a>
        <a className="button" href={REPO}>
          Source
        </a>
      </div>
    </header>
  );
}

export default function App() {
  return (
    <div className="page">
      <Hero />

      <section className="panel">
        <h2>What it does</h2>
        <ul>
          {FEATURES.map((feature) => (
            <li key={feature}>{feature}</li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Build it</h2>
        <div className="window">
          <div className="titlebar">
            <b />
            terminal
          </div>
          <pre>
            <code>{BUILD}</code>
          </pre>
        </div>
        <p className="note">
          Needs Zig 0.16. Nothing else — raylib is fetched by the build.
        </p>
      </section>

      <footer>
        MIT licensed · <a href={REPO}>github.com/IWhitebird/Zimacs</a>
      </footer>
    </div>
  );
}
