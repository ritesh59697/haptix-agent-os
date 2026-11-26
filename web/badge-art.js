// Draws the Guarded Agent card shown on the site, from a badge's on-chain data.
// The token's own image is stored in the contract and can't change; this renders the
// same facts (number, holder, and the attributes in tokenURI) as a nicer card.
window.HaptixBadgeArt = (function () {
  var seq = 0;
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };

  function parse(uri) {
    var json = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(uri.split(',')[1]), function (c) { return c.charCodeAt(0); })));
    var m = /#(\d+)\s*$/.exec(json.name || '');
    var attrs = (json.attributes || []).map(function (a) {
      var unit = /\(hours\)/i.test(a.trait_type) ? 'h' : /\(days\)/i.test(a.trait_type) ? 'd' : '';
      return { label: String(a.trait_type).replace(/\s*\(.*?\)\s*/g, ''), value: String(a.value) + unit };
    });
    return { number: m ? m[1] : '', attrs: attrs, image: json.image };
  }

  // Returns inline SVG markup (inline so it can use the page's fonts).
  function svg(meta, holder) {
    var k = 'hb' + (++seq), CX = 200, CY = 158, R = 64;
    var pt = function (r, a) { var t = a * Math.PI / 180; return [CX + r * Math.sin(t), CY - r * Math.cos(t)]; };
    var ticks = '';
    for (var i = 0; i <= 54; i++) {
      var a = -135 + i * 5, maj = i % 9 === 0, p1 = pt(maj ? R - 10 : R - 6, a), p2 = pt(R, a);
      ticks += '<line x1="' + p1[0].toFixed(1) + '" y1="' + p1[1].toFixed(1) + '" x2="' + p2[0].toFixed(1) + '" y2="' + p2[1].toFixed(1) + '" stroke="#9C7418" stroke-opacity="' + (maj ? 0.9 : 0.4) + '" stroke-width="' + (maj ? 1.6 : 1) + '"/>';
    }
    var arcA = pt(R + 9, -135), arcB = pt(R + 9, 135);
    var rings = '';
    for (var r = 26; r < 340; r += 9) rings += '<circle cx="330" cy="40" r="' + r + '"/>';
    var cols = meta.attrs.slice(0, 3), w = 312 / Math.max(1, cols.length), rows = '';
    cols.forEach(function (c, i) {
      var x = 44 + i * w;
      if (i) rows += '<line x1="' + (x - 12) + '" y1="296" x2="' + (x - 12) + '" y2="336" stroke="#9C7418" stroke-opacity="0.22"/>';
      rows += '<text x="' + x + '" y="304" font-family="JetBrains Mono, ui-monospace, monospace" font-size="9" letter-spacing="1.6" fill="#8A8170">' + esc(c.label.toUpperCase()) + '</text>' +
              '<text x="' + x + '" y="330" font-family="Instrument Serif, Georgia, serif" font-size="24" fill="#1F1C15">' + esc(c.value) + '</text>';
    });
    var who = holder ? holder.slice(0, 6) + '…' + holder.slice(-4) : '';
    return '<svg viewBox="0 0 400 400" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Haptix Guarded Agent No. ' + esc(meta.number) + '">' +
      '<defs>' +
        '<linearGradient id="' + k + 'g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7A5A14"/><stop offset=".25" stop-color="#F7DA7E"/><stop offset=".5" stop-color="#C08A22"/><stop offset=".72" stop-color="#FFF0B3"/><stop offset="1" stop-color="#8A6418"/></linearGradient>' +
        '<linearGradient id="' + k + 's" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFE9A3"/><stop offset="1" stop-color="#D49A1C"/></linearGradient>' +
        '<radialGradient id="' + k + 'b" cx=".7" cy=".15" r="1"><stop offset="0" stop-color="#FFFDF6"/><stop offset=".6" stop-color="#F8F2E2"/><stop offset="1" stop-color="#EFE6CF"/></radialGradient>' +
        '<clipPath id="' + k + 'c"><rect x="0" y="0" width="400" height="400" rx="28"/></clipPath>' +
      '</defs>' +
      '<g clip-path="url(#' + k + 'c)">' +
        '<rect width="400" height="400" fill="url(#' + k + 'b)"/>' +
        '<g fill="none" stroke="#B8901F" stroke-opacity="0.09">' + rings + '</g>' +
        '<circle cx="' + CX + '" cy="' + CY + '" r="110" fill="#F2C94C" fill-opacity="0.16"/>' +
      '</g>' +
      '<rect x="10" y="10" width="380" height="380" rx="22" fill="none" stroke="url(#' + k + 'g)" stroke-width="1.6"/>' +
      '<rect x="17" y="17" width="366" height="366" rx="17" fill="none" stroke="#B8901F" stroke-opacity="0.3"/>' +
      '<text x="40" y="54" font-family="JetBrains Mono, ui-monospace, monospace" font-size="11" letter-spacing="3" fill="#8A5D05">HAPTIX</text>' +
      '<text x="360" y="58" text-anchor="end" font-family="Instrument Serif, Georgia, serif" font-style="italic" font-size="26" fill="#1F1C15">No. ' + esc(meta.number) + '</text>' +
      ticks +
      '<path d="M' + arcA[0].toFixed(1) + ' ' + arcA[1].toFixed(1) + ' A' + (R + 9) + ' ' + (R + 9) + ' 0 1 1 ' + arcB[0].toFixed(1) + ' ' + arcB[1].toFixed(1) + '" fill="none" stroke="url(#' + k + 'g)" stroke-width="2"/>' +
      '<circle cx="' + CX + '" cy="' + CY + '" r="40" fill="#FFFDF6" stroke="url(#' + k + 'g)" stroke-width="1.2"/>' +
      '<g transform="translate(' + (CX - 22) + ' ' + (CY - 22) + ') scale(1.375)">' +
        '<path d="M4 8C4 5.24 6.24 3 9 3H10C11.1 3 12 3.9 12 5V12.2L16.2 14.6L12 16.8V27C12 28.1 11.1 29 10 29H9C6.24 29 4 26.76 4 24V8Z" fill="url(#' + k + 's)"/>' +
        '<path d="M28 24C28 26.76 25.76 29 23 29H22C20.9 29 20 28.1 20 27V19.8L15.8 17.4L20 15.2V5C20 3.9 20.9 3 22 3H23C25.76 3 28 5.24 28 8V24Z" fill="url(#' + k + 'g)"/>' +
      '</g>' +
      '<text x="200" y="266" text-anchor="middle" font-family="Instrument Serif, Georgia, serif" font-size="40" fill="#1F1C15">Guarded <tspan font-style="italic" fill="#8A5D05">Agent</tspan></text>' +
      '<line x1="32" y1="282" x2="368" y2="282" stroke="#9C7418" stroke-opacity="0.22"/>' +
      rows +
      '<line x1="32" y1="350" x2="368" y2="350" stroke="#9C7418" stroke-opacity="0.22"/>' +
      '<text x="40" y="372" font-family="JetBrains Mono, ui-monospace, monospace" font-size="10" letter-spacing="0.5" fill="#7A7262">' + esc(who) + '</text>' +
      '<text x="360" y="372" text-anchor="end" font-family="Instrument Serif, Georgia, serif" font-style="italic" font-size="15" fill="#8A5D05">Soulbound · BNB Chain</text>' +
    '</svg>';
  }

  return { parse: parse, svg: svg };
})();
