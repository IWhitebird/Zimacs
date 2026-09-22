const REPO = "https://github.com/IWhitebird/Zimacs";

const FEATURES = [
  "Piece-tree text storage, so edits stay fast in large files",
  "Tabs, undo and redo, selection by keyboard and mouse",
  "Find, go to line, and a file browser drawn in the editor",
  "Session restore — unsaved work comes back next time",
  "Optional line wrapping, UTF-8 throughout, configurable colours",
  "One binary. No toolkit to install, no runtime, font included",
];

function Header() {
  return (
    <header>
      <img src="/Zimacs/logo.png" alt="Zimacs" />
      <h1>Zimacs</h1>
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
      <Header />

      <section>
        <h2>What it does</h2>
        <ul>
          {FEATURES.map((feature) => (
            <li key={feature}>{feature}</li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Build it</h2>
        <pre>
          <code>{`git clone ${REPO}\ncd Zimacs\nzig build run`}</code>
        </pre>
        <p className="tagline">
          Needs Zig 0.16. Nothing else — raylib is fetched by the build.
        </p>
      </section>

      <footer>
        MIT licensed · <a href={REPO}>github.com/IWhitebird/Zimacs</a>
      </footer>
    </div>
  );
}
