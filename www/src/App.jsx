import { useEffect, useState } from "react";
import { Linux, Windows, Web, Laptop, GitHub, Zig, Scale } from "./Icons.jsx";

const REPO = "https://github.com/IWhitebird/Zimacs";
const RAW =
  "https://raw.githubusercontent.com/IWhitebird/Zimacs/master/scripts";
const DEMO = "/demo/Zimacs.html";

const INSTALL = {
  Linux: `curl -fsSL ${RAW}/install.sh | sh`,
  Windows: `irm ${RAW}/install.ps1 | iex`,
};

const PLATFORMS = [
  {
    icon: Linux,
    name: "Linux",
    arch: "x86_64",
    state: "ready",
    note: "One line to install. Lands in your applications menu.",
  },
  {
    icon: Windows,
    name: "Windows",
    arch: "x86_64",
    state: "ready",
    note: "One line to install. Start Menu shortcut and on your PATH.",
  },
  {
    icon: Web,
    name: "Browser",
    arch: "wasm",
    state: "ready",
    note: "The whole editor compiled to WebAssembly. Try it above.",
  },
  {
    icon: Laptop,
    name: "macOS",
    arch: "arm64",
    state: "soon",
    note: "Compiles and links, but needs the Apple SDK to finish. No build yet.",
  },
];

const FEATURES = [
  {
    title: "Piece tree",
    body: "The storage design VS Code uses. Edits stay fast in large files instead of copying the whole buffer around. Try the 269,649 line tab above.",
  },
  {
    title: "Session restore",
    body: "Unsaved work comes back next time you open it, Notepad++ style. Closing the window loses nothing.",
  },
  {
    title: "Real editing",
    body: "Tabs, undo and redo, selection by keyboard and mouse, find, go to line, and a file browser drawn in the editor.",
  },
  {
    title: "One binary",
    body: "No toolkit, no runtime, no config required. The font is baked into the executable.",
  },
  {
    title: "Text done properly",
    body: "UTF-8 throughout, tabs and wide characters measured in real columns, optional line wrapping.",
  },
  {
    title: "Yours to set up",
    body: "Colours, font size, caret style and tab width all come from a plain text file you can open from the menu.",
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
        Installs under your home directory and adds Zimacs to your{" "}
        {os === "Linux" ? "applications menu" : "Start Menu"}. No root needed.{" "}
        <a href={`${REPO}/releases/latest`}>Prefer a direct download?</a>
      </p>
    </div>
  );
}

/* The poster the demo sits behind: a drawing of the editor with its file
   browser open, so the frame is not an empty rectangle before you launch it. */
function Poster() {
  const TREE = [
    ["dir", "src/"],
    ["file", "main.zig"],
    ["file", "piecetree.zig"],
    ["file", "buffer.zig"],
    ["file", "editor.zig"],
    ["dir", "assets/"],
    ["file", "README.md"],
  ];

  return (
    <div className="poster" aria-hidden="true">
      <div className="tabbar">
        <span className="tab-chip on">main.zig</span>
        <span className="tab-chip">piecetree.zig</span>
        <span className="tab-chip dirty">notes.md</span>
      </div>
      <div className="body">
        <div className="tree">
          {TREE.map(([kind, name]) => (
            <span key={name} className={kind}>
              {name}
            </span>
          ))}
        </div>
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
          <div>{"    "}self.history.record(.insert, at);</div>
          <div>{"}"}</div>
        </div>
      </div>
      <div className="status">
        <span>main.zig</span>
        <span className="right">Ln 44, Col 32 &nbsp; UTF-8 &nbsp; Zig</span>
      </div>
    </div>
  );
}

function Demo() {
  // The demo is built by a separate script, so the page has to cope with it
  // being absent. The iframe starts loading immediately either way.
  const [missing, setMissing] = useState(false);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetch(DEMO, { method: "HEAD" })
      .then((r) => !cancelled && !r.ok && setMissing(true))
      .catch(() => !cancelled && setMissing(true));
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    function onMessage(e) {
      if (e.data && e.data.zimacs === "ready") setReady(true);
    }
    window.addEventListener("message", onMessage);
    // If the shell never reports in, stop covering a working editor.
    const giveUp = setTimeout(() => setReady(true), 15000);
    return () => {
      window.removeEventListener("message", onMessage);
      clearTimeout(giveUp);
    };
  }, []);

  return (
    <section className="demo" id="try">
      <h2>Try it here</h2>
      <p className="lede">
        This is the editor itself, compiled to WebAssembly and running in your
        browser. Same piece tree, same keybindings, same code as the download.
        Click into it and type. The second tab holds the SQLite amalgamation,
        9.5 MB and 269,649 lines of C, so you can see what the piece tree does
        with a file that size. Opening and saving your own files are the only
        things turned off, because a page has no filesystem.
      </p>

      <div className="stage">
        {missing ? (
          <>
            <Poster />
            <div className="veil">
              <div className="veil-inner">
                <p className="veil-note">The demo has not been built yet.</p>
                <code className="veil-cmd">sh scripts/build-demo.sh</code>
              </div>
            </div>
          </>
        ) : (
          <>
            <iframe
              className="frame"
              src={DEMO}
              title="Zimacs running in the browser"
              allow="clipboard-write"
            />
            {!ready && (
              <div className="veil loading">
                <div className="veil-inner">
                  <div className="bar" aria-hidden="true">
                    <i />
                  </div>
                  <p className="veil-note">Starting the editor</p>
                </div>
              </div>
            )}
          </>
        )}
      </div>

      <p className="fineprint">
        Click inside it first so it takes the keyboard. Then <kbd>Ctrl</kbd>+
        <kbd>F</kbd> to find, <kbd>Ctrl</kbd>+<kbd>D</kbd> to duplicate a line,{" "}
        <kbd>Ctrl</kbd>+<kbd>Z</kbd> to undo. Your browser keeps <kbd>Ctrl</kbd>
        +<kbd>W</kbd> and <kbd>Ctrl</kbd>+<kbd>T</kbd> for itself, so use the
        File menu for tabs.
      </p>
    </section>
  );
}

function Platforms() {
  return (
    <section id="platforms">
      <h2>Where it runs</h2>
      <div className="platforms">
        {PLATFORMS.map((p) => {
          const Icon = p.icon;
          return (
            <article className={`plat ${p.state}`} key={p.name}>
              <Icon className="plat-icon" width="26" height="26" />
              <div className="plat-head">
                <h3>{p.name}</h3>
                <span className="arch">{p.arch}</span>
              </div>
              <p>{p.note}</p>
              <span className="badge">
                {p.state === "ready" ? "available" : "not yet"}
              </span>
            </article>
          );
        })}
      </div>
    </section>
  );
}

export default function App() {
  return (
    <>
      <nav className="nav">
        <div className="wrap nav-inner">
          <a className="nav-brand" href="#top">
            <img src="/logo.png" alt="" width="22" height="22" />
            Zimacs
          </a>
          <div className="nav-links">
            <a href="#try">Try it</a>
            <a href="#features">Features</a>
            <a href="#platforms">Platforms</a>
            <a className="nav-gh" href={REPO}>
              <GitHub width="15" height="15" />
              GitHub
            </a>
          </div>
        </div>
      </nav>

      <header className="hero" id="top">
        <Sun />
        <div className="wrap">
          <img className="mark" src="/logo.png" alt="" width="96" height="96" />
          <h1 className="wordmark">ZIMACS</h1>
          <p className="tagline">
            A small, fast, self-contained text editor written in Zig.
          </p>
          <Install />
          <a className="jump" href="#try">
            or try it in your browser, no install
          </a>
        </div>
      </header>

      <main className="wrap">
        <Demo />

        <section id="features">
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

        <Platforms />

        <section id="source">
          <h2>Source</h2>
          <a className="source" href={REPO}>
            <GitHub className="source-mark" width="40" height="40" />
            <span className="source-repo">IWhitebird/Zimacs</span>
            <span className="source-go">View on GitHub</span>
          </a>
          <div className="facts">
            <span>
              <Zig width="20" height="18" /> Written in Zig
            </span>
            <span>
              <Scale width="15" height="15" /> MIT licensed
            </span>
            <span>
              <GitHub width="15" height="15" /> Issues and pull requests welcome
            </span>
          </div>
        </section>
      </main>

      <footer className="wrap">
        <span>A text editor written in Zig.</span>
        <a href={REPO}>github.com/IWhitebird/Zimacs</a>
      </footer>
    </>
  );
}
