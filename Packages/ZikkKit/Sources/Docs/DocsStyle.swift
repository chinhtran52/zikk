import Foundation

enum DocsStyle {
    static let css = """
    :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --panel: #f5f5f7; --border: #d2d2d7; --accent: #0a84ff;
      --get: #1f9d55; --post: #d97706; --put: #2563eb; --patch: #7c3aed; --delete: #dc2626; --other: #0d9488; }
    @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e; --panel: #2c2c2e; --border: #3a3a3c; } }
    * { box-sizing: border-box; }
    body { margin: 0; font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg); }
    .layout { display: grid; grid-template-columns: 260px 1fr; min-height: 100vh; }
    nav { position: sticky; top: 0; height: 100vh; overflow: auto; padding: 20px 12px; border-right: 1px solid var(--border); background: var(--panel); }
    nav h2 { font-size: 15px; margin: 0 0 12px; }
    nav a { display: flex; gap: 6px; align-items: baseline; color: var(--fg); text-decoration: none; padding: 3px 6px; border-radius: 6px; font-size: 13px; }
    nav a:hover { background: var(--border); }
    nav .folder { margin: 12px 0 4px; font-weight: 600; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
    .content { padding: 28px 40px; max-width: 980px; }
    h1 { font-size: 28px; margin: 0 0 8px; } h2 { margin-top: 36px; } h3 { margin: 18px 0 8px; font-size: 15px; }
    .endpoint { border-top: 1px solid var(--border); padding-top: 24px; margin-top: 28px; }
    .url { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; overflow-x: auto; }
    .method { font: 700 11px ui-monospace, Menlo, monospace; color: #fff; border-radius: 4px; padding: 2px 6px; min-width: 52px; text-align: center; display: inline-block; }
    nav .method { min-width: 42px; font-size: 9.5px; padding: 1px 4px; }
    .GET { background: var(--get); } .POST { background: var(--post); } .PUT { background: var(--put); } .PATCH { background: var(--patch); } .DELETE { background: var(--delete); }
    .OTHER { background: var(--other); }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { text-align: left; border-bottom: 1px solid var(--border); padding: 6px 8px; vertical-align: top; }
    th { color: var(--muted); font-weight: 600; }
    td code, .mono { font-family: ui-monospace, Menlo, monospace; }
    pre { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 12px; overflow-x: auto; font: 12.5px/1.5 ui-monospace, Menlo, monospace; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 12.5px; }
    .muted { color: var(--muted); } .badge { font-size: 11px; border: 1px solid var(--border); border-radius: 10px; padding: 1px 8px; color: var(--muted); }
    .status { font-weight: 600; } .s2 { color: var(--get); } .s3 { color: var(--put); } .s4 { color: var(--post); } .s5 { color: var(--delete); }
    details { margin: 8px 0; } summary { cursor: pointer; font-weight: 600; }
    .disabled td { opacity: .55; }
    .markdown img { max-width: 100%; }
    @media (max-width: 720px) { .layout { grid-template-columns: 1fr; } nav { position: static; height: auto; } .content { padding: 20px; } }
    """
}
