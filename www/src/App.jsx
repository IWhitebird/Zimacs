import { useState } from "react";

const REPO = "https://github.com/IWhitebird/Zimacs";
const RAW = "https://raw.githubusercontent.com/IWhitebird/Zimacs/master";

const INSTALL = {
  Linux: `curl -fsSL ${RAW}/install.sh | sh`,
  Windows: `irm ${RAW}/install.ps1 | iex`,
};

const FEATURES = [
  {
    title: "Piece tree",
    body: "The storage design VS Code uses. Edits stay fast in large files instead of copying the whole buffer.",
  },
  {
    title: "Session restore",
    body: "Unsaved work comes back next time you open it, Notepad++ style. Nothing is lost by closing the window.",
  },
  {
    title: "Real editing",
    body: "Tabs, undo and redo, selection by keyboard and mouse, find, go to line, and a file browser drawn in the editor.",
  },
  {
    title: "One binary",
    body: "No toolkit to install, no runtime, no config needed. The font ships inside the executable.",
  },
  {
    title: "Text done properly",
    body: "UTF-8 throughout, tabs and wide characters measured in real columns, optional line wrapping.",
  },
  {
    title: "Yours to set up",
    body: "Colours, font size and caret style all come from a plain config file you can open from the menu.",
  },
];

/* The sun: a solid core under three rings of dots that shrink outward, which
   is what makes it read as a halftone screen rather than a gradient. */
function Sun() {
  return (
    <div className="sun" aria-hidden="true">
      <i className="b1" />
      <i className="b2" />
      <i className="b3" />
    </div>
  );
}

function Install() {
  const [os, setOs] = useState("Linux");
  const [copied, setCopied] = useState(false);

  function copy() {
    navigator.clipboard?.writeText(INSTALL[os]).then(
      () => {
        setCopied(true);
        setTimeout(() => setCopied(false), 1400);
      },
      () => {},
    );
  }

  return (
    <div className="install">
      <div className="tabs" role="tablist">
        {Object.keys(INSTALL).map((name) => (
          <button
            key={name}
            role="tab"
            aria-selected={os === name}
            className={os === name ? "tab on" : "tab"}
            onClick={() => setOs(name)}
          >
            {name}
          </button>
        ))}
        <button className="copy" onClick={copy}>
          {copied ? "copied" : "copy"}
        </button>
      </div>
      <pre className="cmd">
        <span className="prompt">$</span>
        <code>{INSTALL[os]}</code>
      </pre>
      <p className="fineprint">
        Installs to your home directory and adds Zimacs to your{" "}
        {os === "Linux" ? "applications menu" : "Start Menu"}. No root needed.{" "}
        <a href={`${REPO}/releases/latest`}>Prefer a direct download?</a>
      </p>
    </div>
  );
}

/* A drawing of the editor rather than a screenshot, so it stays in the site's
   two inks and costs nothing to load. */
function Screenshot() {
  return (
    <div className="editor" aria-hidden="true">
      <div className="tabbar">
        <span className="tab-chip on">main.zig</span>
        <span className="tab-chip">piecetree.zig</span>
        <span className="tab-chip dirty">notes.md</span>
      </div>
      <div className="body">
        <div className="gutter">
          {[41, 42, 43, 44, 45, 46, 47].map((n) => (
            <span key={n} className={n === 44 ? "cur" : ""}>
              {n}
            </span>
          ))}
        </div>
        <div className="code">
          <div>
            <span className="k">pub fn</span> <span className="f">edit</span>
            (self: *BufferView, at: u32) !<span className="t">void</span> {"{"}
          </div>
          <div>
            {"    "}
            <span className="c">// every edit funnels through here</span>
          </div>
          <div>
            {"    "}
            <span className="k">try</span> self.tree.insert(at, text);
          </div>
          <div className="hl">
            {"    "}self.cursor.offset = at + text.len;
            <span className="caret" />
          </div>
          <div>
            {"    "}self.history.record(.insert, at);
          </div>
          <div>{"}"}</div>
          <div />
        </div>
      </div>
      <div className="status">
        <span>main.zig</span>
        <span className="right">Ln 44, Col 32 &nbsp; UTF-8 &nbsp; Zig</span>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <>
      <header className="hero">
        <Sun />
        <div className="wrap">
          <img className="mark" src="/logo.png" alt="" width="96" height="96" />
          <h1 className="wordmark">ZIMACS</h1>
          <p className="tagline">
            A small, fast, self-contained text editor written in Zig.
          </p>
          <Install />
        </div>
      </header>

      <main className="wrap">
        <section className="showcase">
          <Screenshot />
        </section>

        <section>
          <h2>What it does</h2>
          <div className="grid">
            {FEATURES.map((f) => (
              <article className="card" key={f.title}>
                <h3>{f.title}</h3>
                <p>{f.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section>
          <h2>Build from source</h2>
          <div className="window">
            <div className="titlebar">
              <b />
              terminal
            </div>
            <pre>
              <code>{`git clone ${REPO}\ncd Zimacs\nzig build run`}</code>
            </pre>
          </div>
          <p className="fineprint">
            Needs Zig 0.16 and nothing else. raylib is fetched by the build.
          </p>
        </section>
      </main>

      <footer className="wrap">
        <span>MIT licensed</span>
        <a href={REPO}>github.com/IWhitebird/Zimacs</a>
      </footer>
    </>
  );
}
