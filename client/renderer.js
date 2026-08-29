// Contagion shared renderer + drivers.
//
// One canvas scene — the six regions on a painted map plate, at the vertices
// of a hexagon, with the nine roads inked between them (six thick ring roads,
// three thin back roads). Each region is a painted tile carrying its name,
// its governor portrait in the seat colour, a red stain whose coverage tracks
// TRUE prevalence, 0–4 wooden shutters for its lockdown, a testing lantern,
// and its GDP and death tickers. Every road carries a barrier arm at each end
// and a crawling red seep whose thickness is the imported case count — a road
// that is shut and still seeping is the picture the whole game is about.
// Under the map an epi strip charts every region's true infections against
// the hospital-capacity line, with its REPORTED curve dotted underneath.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {seats:[{seat,pos,region,name,score,gdp,deaths,deathsWeek,infected,
//            confirmed,confirmedNew,newInfections,susceptible,recovered,alive,
//            lockdown,testing,hospital,gates:[{to,pos,gate,eff,road}×3],
//            grossGdp,spendWeek,aidIn,aidOut,aid:[{to,amount}],say,heard[],
//            notes,pending} ×6 by SEAT],
//    posSeat[6], regions[6], edges:[{a,b,road,eff,flow}×9],
//    week, weeks, weeksPlayed, variant, curves:{infected,deaths,gdp,confirmed},
//    hospitalCap, phase:"dials|done", gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Regions
  // are laid out by POSITION but coloured by SEAT, so a seat keeps its colour
  // across episodes.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var PLAGUE = "#c4372a";
  var ROAD = "#6b5334";
  var GOLD = "#e8c15a";
  var HOSPITAL_BANDS = ["normal", "strained", "overloaded", "critical"];
  var PORTRAITS = ["governor_red_front.png", "governor_blue_front.png",
    "governor_green_front.png", "governor_yellow_front.png",
    "governor_violet_front.png", "governor_orange_front.png"];
  // Timing of the week transition.
  var SHUTTER_MS = 500;
  var AID_MS = 700;
  var BUBBLE_HOLD_MS = 6000;
  var DEATH_FLASH_MS = 900;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = PORTRAITS.concat(["map_board.png", "region_tile.png",
      "shutter.png", "gate_arm.png", "aid_packet.png"]);
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Credits and people are always drawn as grouped integers — "14,402", never
  // "1.4e4": a casual spectator reads numbers, not notation.
  function num(value) {
    var n = Math.round(value || 0);
    var sign = n < 0 ? "-" : "";
    return sign + String(Math.abs(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function shortRegion(name, compact) {
    if (!compact) return name;
    return String(name || "").split(" ")[0];
  }

  // ---- Layout --------------------------------------------------------------

  // Six regions on a hexagon over the map plate; the epi strip takes the
  // bottom. Everything is measured from the hexagon radius so the scene
  // scales to whatever frame the viewer is embedded in — including the
  // ~360 px featured-match iframe.
  function computeLayout(width, height) {
    var margin = 8;
    var stripH = Math.max(66, Math.min(height * 0.26, 150));
    var mapTop = margin;
    var mapH = height - stripH - margin * 2;
    var scale = Math.min(width / 960, height / 640);
    var size = Math.max(38, Math.min(112, width * 0.17, mapH * 0.27));
    var cx = width / 2;
    var cy = mapTop + mapH / 2;
    var rx = Math.max(size * 0.95, width / 2 - margin - size * 0.62);
    var ry = Math.max(size * 0.72, mapH / 2 - size * 0.62);
    var nodes = [];
    for (var p = 0; p < 6; p++) {
      var angle = -Math.PI / 2 + p * Math.PI / 3;
      nodes.push({
        x: cx + rx * Math.cos(angle),
        y: cy + ry * Math.sin(angle)
      });
    }
    return {
      width: width, height: height, scale: scale, size: size,
      mapTop: mapTop, mapH: mapH, cx: cx, cy: cy, rx: rx, ry: ry,
      nodes: nodes, compact: width < 640,
      strip: { x: margin, y: height - stripH - margin, w: width - 2 * margin,
        h: stripH }
    };
  }

  // A road as a quadratic curve. The three back roads are diameters, so each
  // is bowed off the centre; otherwise all three would overlap in a knot.
  var BACK_BOW = { "0,3": 1, "1,4": 1, "2,5": 1 };
  function roadPath(L, edge) {
    var a = L.nodes[edge.a];
    var b = L.nodes[edge.b];
    var mx = (a.x + b.x) / 2;
    var my = (a.y + b.y) / 2;
    var bow = BACK_BOW[edge.a + "," + edge.b] && edge.road === "back" ?
      0.22 : 0;
    var dx = b.x - a.x;
    var dy = b.y - a.y;
    var len = Math.max(1, Math.hypot(dx, dy));
    return {
      x0: a.x, y0: a.y, x1: b.x, y1: b.y,
      cx: mx + (-dy / len) * len * bow,
      cy: my + (dx / len) * len * bow
    };
  }

  function pointOnRoad(path, t) {
    var u = 1 - t;
    return {
      x: u * u * path.x0 + 2 * u * t * path.cx + t * t * path.x1,
      y: u * u * path.y0 + 2 * u * t * path.cy + t * t * path.y1
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var posSeat = view.posSeat || [0, 1, 2, 3, 4, 5];
    var edges = view.edges || [];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var fx = view.effects || {};

    // Stage.
    ctx.fillStyle = "#16110d";
    ctx.fillRect(0, 0, w, h);
    var board = images["map_board.png"];
    if (board && board.width) {
      ctx.save();
      ctx.globalAlpha = 0.96;
      ctx.drawImage(board, 0, L.mapTop, w, L.mapH);
      ctx.restore();
    }

    var byPos = [];
    for (var p = 0; p < 6; p++) {
      byPos.push(seats[posSeat[p]] || null);
    }

    // Roads, back roads first so the ring reads on top.
    edges.forEach(function (edge) {
      if (edge.road === "back") drawRoad(ctx, images, L, edge, byPos, now, fx);
    });
    edges.forEach(function (edge) {
      if (edge.road !== "back") drawRoad(ctx, images, L, edge, byPos, now, fx);
    });

    // Leader, once anyone is ahead.
    var best = -Infinity;
    var level = true;
    seats.forEach(function (s) { if (s.score > best) best = s.score; });
    seats.forEach(function (s) { if (s.score !== best) level = false; });

    for (var q = 0; q < 6; q++) {
      var seat = byPos[q];
      if (!seat) continue;
      drawRegion(ctx, images, L, q, posSeat[q], seat, view, {
        now: now,
        pending: seat.pending && !view.done,
        leads: view.done && !level && seat.score === best,
        shutterAt: fx.shutterAt ? fx.shutterAt[q] : null,
        shutterFrom: fx.shutterFrom ? fx.shutterFrom[q] : seat.lockdown,
        deathAt: fx.deathAt ? fx.deathAt[q] : null,
        sayAt: fx.sayAt ? fx.sayAt[q] : null,
        say: fx.lastSay ? fx.lastSay[q] : ""
      });
    }

    // Aid packets fly last so they land on top of the tiles.
    (fx.aid || []).forEach(function (packet) {
      var age = now - packet.at;
      if (age < 0 || age > AID_MS) return;
      drawAidPacket(ctx, images, L, packet, age / AID_MS);
    });

    drawEpiStrip(ctx, L, view, posSeat);
  }

  function drawRoad(ctx, images, L, edge, byPos, now, fx) {
    var path = roadPath(L, edge);
    var main = edge.road !== "back";
    var scale = L.scale;
    var wide = Math.max(2, (main ? 7 : 4) * scale);

    ctx.save();
    ctx.lineCap = "round";
    ctx.strokeStyle = rgba(INK, 0.55);
    ctx.lineWidth = wide + 2 * scale;
    ctx.beginPath();
    ctx.moveTo(path.x0, path.y0);
    ctx.quadraticCurveTo(path.cx, path.cy, path.x1, path.y1);
    ctx.stroke();
    ctx.strokeStyle = ROAD;
    ctx.lineWidth = wide;
    ctx.beginPath();
    ctx.moveTo(path.x0, path.y0);
    ctx.quadraticCurveTo(path.cx, path.cy, path.x1, path.y1);
    ctx.stroke();

    // The seep: red beading crawling along the road, thickness set by the
    // imported case count. A shut road still seeping is the leak, drawn.
    var flow = edge.flow || 0;
    if (flow > 0) {
      var beads = Math.max(3, Math.min(14, Math.round(Math.log(flow + 1) * 2)));
      var drift = ((now / 900) % 1);
      var thickness = Math.max(1.4,
        Math.min(wide * 0.9, Math.log(flow + 1) * scale));
      for (var i = 0; i < beads; i++) {
        var t = ((i / beads) + drift) % 1;
        var pt = pointOnRoad(path, t);
        ctx.fillStyle = rgba(PLAGUE, edge.eff >= 2 ? 0.95 : 0.75);
        ctx.beginPath();
        ctx.arc(pt.x, pt.y, thickness, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    ctx.restore();

    // Barrier arms at each end. The tighter end is solid, the looser one
    // ghosted, so "who paid for this closure" reads at a glance.
    var seatA = byPos[edge.a];
    var seatB = byPos[edge.b];
    drawGateArm(ctx, images, L, path, 0.16, gateOf(seatA, edge.b), edge.eff);
    drawGateArm(ctx, images, L, path, 0.84, gateOf(seatB, edge.a), edge.eff);
    void fx;
  }

  function gateOf(seat, farPos) {
    if (!seat || !seat.gates) return 0;
    for (var i = 0; i < seat.gates.length; i++) {
      if (seat.gates[i].pos === farPos) return seat.gates[i].gate;
    }
    return 0;
  }

  function drawGateArm(ctx, images, L, path, t, gate, eff) {
    var pt = pointOnRoad(path, t);
    var ahead = pointOnRoad(path, Math.min(1, t + 0.04));
    var angle = Math.atan2(ahead.y - pt.y, ahead.x - pt.x);
    var scale = L.scale;
    var arm = Math.max(10, 18 * scale);
    // The tighter end governs the road, so it is drawn solid and the looser
    // end ghosted: "who paid for this closure" reads at a glance.
    var tighter = gate >= eff;
    ctx.save();
    ctx.translate(pt.x, pt.y);
    ctx.rotate(angle);
    ctx.globalAlpha = tighter ? 1 : 0.4;
    // Post.
    ctx.fillStyle = INK;
    ctx.fillRect(-Math.max(1, 1.5 * scale), -arm * 0.6,
      Math.max(2, 3 * scale), arm * 0.6);
    // Arm: raised at 0, half at 1, dropped and chained at 2.
    ctx.rotate(gate === 0 ? -Math.PI / 2.2 : gate === 1 ? -Math.PI / 5 : 0);
    var sprite = images["gate_arm.png"];
    var armH = Math.max(4, arm * 0.28);
    if (sprite && sprite.width) {
      ctx.drawImage(sprite, -armH * 0.4, -armH / 2, arm, armH);
    } else {
      ctx.fillStyle = gate === 2 ? PLAGUE : PAPER;
      ctx.fillRect(0, -armH / 2, arm, armH);
    }
    if (gate === 2) {
      // Chained: a red bar under the arm.
      ctx.strokeStyle = PLAGUE;
      ctx.lineWidth = Math.max(1.5, 2 * scale);
      ctx.beginPath();
      ctx.moveTo(0, armH * 0.9);
      ctx.lineTo(arm, armH * 0.9);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawRegion(ctx, images, L, pos, seatIndex, seat, view, opts) {
    var node = L.nodes[pos];
    var size = L.size;
    var scale = L.scale;
    var color = seatColor(seatIndex);
    var tileW = size * 1.5;
    var tileH = size * 1.18;
    var x = node.x - tileW / 2;
    var y = node.y - tileH / 2;

    // Painted tile.
    var tile = images["region_tile.png"];
    ctx.save();
    if (tile && tile.width) {
      ctx.drawImage(tile, x, y, tileW, tileH);
    } else {
      ctx.fillStyle = "rgba(242, 232, 216, 0.10)";
      roundRect(ctx, x, y, tileW, tileH, 6 * scale);
      ctx.fill();
    }
    ctx.restore();

    // The outbreak: an organic red stain whose coverage and opacity track
    // TRUE prevalence. Spectators see the virus; governors never do.
    var alive = seat.alive || 1;
    var prevalence = Math.max(0, Math.min(1, (seat.infected || 0) / alive * 8));
    if (prevalence > 0.001) {
      ctx.save();
      ctx.beginPath();
      roundRect(ctx, x, y, tileW, tileH, 6 * scale);
      ctx.clip();
      var blobs = 7;
      ctx.fillStyle = rgba(PLAGUE, 0.18 + 0.5 * prevalence);
      for (var b = 0; b < blobs; b++) {
        var a = b * 2.399963;
        var rr = Math.sqrt((b + 1) / blobs) * Math.max(tileW, tileH) * 0.42 *
          Math.pow(prevalence, 0.45);
        ctx.beginPath();
        ctx.ellipse(node.x + Math.cos(a) * tileW * 0.18,
          node.y + Math.sin(a) * tileH * 0.18,
          rr, rr * 0.78, a, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    }

    // Shutters slam: 0..4 boards descending over the tile.
    var shutter = images["shutter.png"];
    var from = typeof opts.shutterFrom === "number" ? opts.shutterFrom :
      seat.lockdown;
    var t = typeof opts.shutterAt === "number" ?
      Math.min(1, (opts.now - opts.shutterAt) / SHUTTER_MS) : 1;
    var boards = from + (seat.lockdown - from) * (1 - Math.pow(1 - t, 3));
    if (boards > 0.01) {
      ctx.save();
      ctx.beginPath();
      roundRect(ctx, x, y, tileW, tileH, 6 * scale);
      ctx.clip();
      var slat = tileH / 4;
      for (var s = 0; s < 4; s++) {
        var cover = Math.max(0, Math.min(1, boards - s));
        if (cover <= 0) break;
        var sh = slat * cover;
        if (shutter && shutter.width) {
          ctx.drawImage(shutter, x, y + s * slat, tileW, sh);
        } else {
          ctx.fillStyle = "rgba(107, 76, 34, 0.85)";
          ctx.fillRect(x, y + s * slat, tileW, sh);
        }
      }
      ctx.restore();
    }

    // Portrait: the nano-banana governor cog, drawn big enough that its prop
    // (sash, gavel, clipboard, megaphone, medkit, key) reads at board scale,
    // anchored by its wheels on the readout strip below. Smoothing stays on:
    // the sprite is a 192 px render, not pixel art.
    var sprite = images[PORTRAITS[seatIndex % PORTRAITS.length]];
    var ps = size * 0.78;
    var font = Math.max(9, 11 * scale);
    var feet = y + tileH - font * 2.5 + 2;
    ctx.save();
    if (sprite && sprite.width) {
      ctx.drawImage(sprite, node.x - ps / 2, feet - ps, ps, ps);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(node.x - ps / 3, node.y - ps / 3, ps / 1.5, ps / 1.5);
    }
    ctx.restore();

    // Testing lantern: dark at 0, brightening through 3. Its glow is
    // literally how far into this region a spectator can see.
    drawLantern(ctx, node.x + tileW * 0.36, y + tileH * 0.22, seat.testing || 0,
      scale);

    // Acting halo while the table waits on this seat.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = Math.max(2, 3 * scale);
      ctx.setLineDash([6, 5]);
      roundRect(ctx, x - 3, y - 3, tileW + 6, tileH + 6, 8 * scale);
      ctx.stroke();
      ctx.restore();
    }
    if (opts.leads) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = Math.max(2, 2.5 * scale);
      roundRect(ctx, x - 2, y - 2, tileW + 4, tileH + 4, 8 * scale);
      ctx.stroke();
      ctx.restore();
    }

    // Region name on a paper nameplate above the tile, in the seat colour, so
    // it reads over both the parchment and the red stain.
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(font * 1.1) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = ellipsize(ctx, shortRegion(seat.region, L.compact),
      tileW * 0.94);
    var plateW = ctx.measureText(label).width + font * 1.2;
    var plateH = font * 1.5;
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    roundRect(ctx, node.x - plateW / 2, y - plateH * 0.55, plateW, plateH,
      3 * scale);
    ctx.fill();
    ctx.strokeStyle = COLOR_HEX[color];
    ctx.lineWidth = Math.max(1.5, 2 * scale);
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.fillText(label, node.x, y + plateH * 0.05);

    // A paper readout strip across the foot of the tile. Without it the
    // numbers sit on whatever is under them — bare parchment at lockdown 0,
    // dark boards at lockdown 4 — and stop being readable exactly when the
    // region is most interesting.
    ctx.fillStyle = "rgba(242, 232, 216, 0.9)";
    ctx.fillRect(x + 3, y + tileH - font * 2.5, tileW - 6, font * 2.2);
    ctx.strokeStyle = "rgba(42, 31, 22, 0.35)";
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 3, y + tileH - font * 2.5, tileW - 6, font * 2.2);

    // Dials and hospital band, inked onto the strip.
    var band = HOSPITAL_BANDS[seat.hospital || 0];
    ctx.font = "700 " + Math.round(Math.max(8, font * 0.78)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = (seat.hospital || 0) >= 2 ? PLAGUE : "rgba(42,31,22,0.8)";
    ctx.fillText("L" + (seat.lockdown || 0) + " · T" + (seat.testing || 0) +
      " · " + band.toUpperCase(), node.x, y + tileH - font * 1.8);

    // Tickers, side by side on the strip: the ledger in ink, the dead in red,
    // and the death count flashes and bumps on any week that killed someone.
    var flash = typeof opts.deathAt === "number" &&
      opts.now - opts.deathAt < DEATH_FLASH_MS;
    var baseline = y + tileH - font * 0.75;
    ctx.font = "700 " + Math.round(font * 1.05) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.fillStyle = INK;
    ctx.fillText(ellipsize(ctx, (L.compact ? "" : "GDP ") + num(seat.gdp),
        tileW * 0.47),
      x + font * 0.6, baseline);
    ctx.textAlign = "right";
    ctx.font = "700 " + Math.round(font * (flash ? 1.3 : 1.05)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = flash ? "#ff2d16" : PLAGUE;
    ctx.fillText(ellipsize(ctx, num(seat.deaths) + (L.compact ? "†" : " DEAD"),
        tileW * 0.47),
      x + tileW - font * 0.6, baseline);
    ctx.restore();

    if (opts.say) {
      var sayAge = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS;
      var alpha = sayAge < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (sayAge - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, node.x, y - 4 * scale, opts.say, tileW * 1.35, scale,
        alpha);
    }
    void view;
  }

  function drawLantern(ctx, x, y, level, scale) {
    var r = Math.max(4, 6 * scale);
    ctx.save();
    if (level > 0) {
      var glow = ctx.createRadialGradient(x, y, 0, x, y, r * (2 + level));
      glow.addColorStop(0, rgba(AMBER, 0.18 * level + 0.16));
      glow.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(x, y, r * (2 + level), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.fillStyle = level > 0 ? AMBER : "#4a3d2e";
    ctx.beginPath();
    ctx.arc(x, y, r * 0.55, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = INK;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
  }

  function drawAidPacket(ctx, images, L, packet, t) {
    var a = L.nodes[packet.from];
    var b = L.nodes[packet.to];
    if (!a || !b) return;
    var mx = (a.x + b.x) / 2;
    var my = (a.y + b.y) / 2 - Math.hypot(b.x - a.x, b.y - a.y) * 0.24;
    var u = 1 - t;
    var x = u * u * a.x + 2 * u * t * mx + t * t * b.x;
    var y = u * u * a.y + 2 * u * t * my + t * t * b.y;
    var scale = L.scale;
    var s = Math.max(12, 20 * scale);
    var sprite = images["aid_packet.png"];
    ctx.save();
    ctx.globalAlpha = 0.35 + 0.65 * Math.sin(Math.PI * Math.min(1, t * 1.2));
    if (sprite && sprite.width) {
      ctx.drawImage(sprite, x - s / 2, y - s / 2, s, s);
    } else {
      ctx.fillStyle = GOLD;
      roundRect(ctx, x - s / 2, y - s / 2, s, s, 3);
      ctx.fill();
    }
    ctx.font = "700 " + Math.round(Math.max(9, 11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = INK;
    ctx.shadowColor = GOLD;
    ctx.shadowBlur = 4;
    ctx.fillText(String(packet.amount), x, y + s * 0.72);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(Math.max(9, 10.5 * scale)) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // The epi strip: every region's TRUE infections per week, seat-coloured,
  // with the hospital-capacity line ghosted across it and — the joke the game
  // is built on — each region's REPORTED curve dotted underneath. When a
  // laggard region runs testing 0 the dotted line stays flat while the solid
  // one goes vertical. Under 640 px the dotted curves go; the truth stays.
  function drawEpiStrip(ctx, rect, view, posSeat) {
    var L = rect;
    var r = L.strip;
    var scale = L.scale;
    var curves = view.curves || {};
    var infected = curves.infected || [];
    var confirmed = curves.confirmed || [];
    var weeks = Math.max(view.weeks || 0, 6);
    var padL = 34 * scale;
    var padR = 8 * scale;
    var padT = 14 * scale;
    var padB = 12 * scale;
    var x0 = r.x + padL;
    var x1 = r.x + r.w - padR;
    var y0 = r.y + padT;
    var y1 = r.y + r.h - padB;
    var maxY = Math.max(view.hospitalCap || 25000, 1000);
    infected.forEach(function (series) {
      series.forEach(function (v) { if (v > maxY) maxY = v; });
    });
    maxY = Math.max(1, maxY * 1.1);
    function px(week) { return x0 + (x1 - x0) * week / weeks; }
    function py(v) { return y1 - (y1 - y0) * Math.min(v, maxY) / maxY; }

    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.62)";
    roundRect(ctx, r.x, r.y, r.w, r.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.font = "700 " + Math.max(9, Math.round(10 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("INFECTED PER REGION" + (L.compact ? "" :
      " · dotted = what they REPORT"), r.x + 8 * scale, r.y + 2 * scale);

    // Hospital capacity: a ghost line across the strip.
    var capY = py(view.hospitalCap || 25000);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.35)";
    ctx.setLineDash([5, 4]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x0, capY);
    ctx.lineTo(x1, capY);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = GHOST;
    ctx.font = "600 " + Math.max(8, Math.round(9 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    ctx.fillText("HOSP", x0 - 3 * scale, capY);

    // Week ticks every 4.
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var wk = 0; wk <= weeks; wk += 4) {
      ctx.fillStyle = GHOST;
      ctx.fillText(String(wk), px(wk), y1 + 1 * scale);
    }

    for (var pos = 0; pos < 6; pos++) {
      var color = COLOR_HEX[seatColor(posSeat[pos])];
      var series = infected[pos] || [];
      if (!L.compact) {
        var reported = confirmed[pos] || [];
        if (reported.length) {
          ctx.strokeStyle = rgba(color, 0.55);
          ctx.lineWidth = 1;
          ctx.setLineDash([3, 3]);
          ctx.beginPath();
          reported.forEach(function (v, i) {
            if (i === 0) ctx.moveTo(px(i), py(v));
            else ctx.lineTo(px(i), py(v));
          });
          ctx.stroke();
          ctx.setLineDash([]);
        }
      }
      if (!series.length) continue;
      ctx.strokeStyle = color;
      ctx.lineWidth = Math.max(1.4, 2 * scale);
      ctx.lineJoin = "round";
      ctx.beginPath();
      series.forEach(function (v, i) {
        if (i === 0) ctx.moveTo(px(i), py(v));
        else ctx.lineTo(px(i), py(v));
      });
      ctx.stroke();
      var last = series.length - 1;
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(px(last), py(series[last]), Math.max(2, 3 * scale), 0,
        Math.PI * 2);
      ctx.fill();
    }

    var nowX = px(view.week || 0);
    ctx.strokeStyle = rgba(AMBER, 0.8);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(nowX, y0 - 3 * scale);
    ctx.lineTo(nowX, y1);
    ctx.stroke();
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear region aliases ("Riverbend", "Saltmarch"); the
  // payload carries the policy names separately, spectator-side only. A name
  // map swaps them in wherever a name is RENDERED while the underlying events
  // keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // `ctx` carries what a line needs from earlier events.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Six regions, nine roads, one virus. Every road leaks 12% " +
          "however tightly it is shut.";
      case "week":
        var regions = event.regions || [];
        var infected = 0;
        var dead = 0;
        regions.forEach(function (r) {
          infected += r.infected || 0;
          dead += r.dead || 0;
        });
        return "Week " + event.week + " — " + num(infected) +
          " infected across the map, " + num(dead) + " dead" +
          (event.variant ? " · VARIANT +25%" : "") + ".";
      case "dial":
        var closes = (event.borders || []).filter(function (b) {
          return b.gate >= 2;
        }).map(function (b) { return nameMap.text(b.to); });
        return name(event.seat) + " — lockdown " + event.lockdown +
          ", testing " + event.testing +
          (closes.length ? ", closes " + closes.join(" and ") : "") +
          (event.scripted ? " (scripted)" : "");
      case "end":
        return "Final — " + (ctx.leader || "no one") + " leads" +
          (event.text === "deadline" ? " — episode deadline." : ".");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "WEEK " + block;
  }

  // Renders the full transcript grouped into one section per week.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = { leader: "" };
    var lastNotes = {};
    var seatOfPos = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var future = i >= limit;
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.week;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      if (event.kind === "dial") seatOfPos[event.pos] = event.seat;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "dial" ? " seat" + (event.seat % COLORS.length) : "") +
        (future ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";

      if (event.kind === "dial") {
        (event.aid || []).forEach(function (entry) {
          html += '<div class="feed-line feed-score' +
            (future ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(event.seat)) + " sends " +
              num(entry.amount) + " to " + nameMap.text(entry.to)) + "</div>";
        });
        if (event.say) {
          html += '<div class="feed-line feed-say' +
            (future ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(event.seat)) + " says: " +
              nameMap.text(event.say)) + "</div>";
        }
        if (event.corrected) {
          html += '<div class="feed-line feed-notes' +
            (future ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(event.seat)) +
              " — reply corrected to a legal move") + "</div>";
        }
        if (event.text && event.text !== lastNotes[event.seat]) {
          lastNotes[event.seat] = event.text;
          html += '<div class="feed-line feed-notes' +
            (future ? " feed-future" : "") + '">' +
            escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
              nameMap.text(event.text)) + "</div>";
        }
      }
      if (event.kind === "week") {
        var best = -Infinity;
        (event.regions || []).forEach(function (region, pos) {
          var seat = seatOfPos[pos];
          var score = (region.gdp || 0) - 2 * (region.dead || 0);
          if (score > best && seat !== undefined) {
            best = score;
            ctx.leader = clampName(nameMap.seat(seat));
          }
          if ((region.deathsWeek || 0) > 0 || (region.hospital || 0) >= 2) {
            html += '<div class="feed-line feed-death' +
              (future ? " feed-future" : "") + '">' +
              escapeHtml((seat === undefined ? "Region " + pos :
                clampName(nameMap.seat(seat))) + " — " +
                num(region.deathsWeek) + " dead this week, hospitals " +
                HOSPITAL_BANDS[region.hospital || 0].toUpperCase()) +
              "</div>";
          }
        });
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when each region's shutters last moved (and from what level), when a week
  // killed someone (the ticker flashes), each region's last message, and the
  // aid packets currently in flight.
  function makeEffects() {
    var seen = 0;
    var shutterAt = [null, null, null, null, null, null];
    var shutterFrom = [0, 0, 0, 0, 0, 0];
    var lockdown = [0, 0, 0, 0, 0, 0];
    var deathAt = [null, null, null, null, null, null];
    var sayAt = [null, null, null, null, null, null];
    var lastSay = ["", "", "", "", "", ""];
    var aid = [];
    function reset() {
      seen = 0;
      shutterAt = [null, null, null, null, null, null];
      shutterFrom = [0, 0, 0, 0, 0, 0];
      lockdown = [0, 0, 0, 0, 0, 0];
      deathAt = [null, null, null, null, null, null];
      sayAt = [null, null, null, null, null, null];
      lastSay = ["", "", "", "", "", ""];
      aid = [];
    }
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "dial") {
            var pos = event.pos;
            if (lockdown[pos] !== event.lockdown) {
              shutterFrom[pos] = lockdown[pos];
              shutterAt[pos] = animate ? now : null;
              lockdown[pos] = event.lockdown;
            }
            if (event.say) {
              lastSay[pos] = event.say;
              sayAt[pos] = animate ? now : null;
            }
            (event.aid || []).forEach(function (entry) {
              if (!animate) return;
              aid.push({ from: pos, to: entry.toPos, amount: entry.amount,
                at: now });
            });
          } else if (event.kind === "week") {
            (event.regions || []).forEach(function (region, p) {
              if ((region.deathsWeek || 0) > 0) {
                deathAt[p] = animate ? now : null;
              }
            });
          }
        }
        aid = aid.filter(function (packet) {
          return Date.now() - packet.at < AID_MS;
        });
      },
      reset: reset,
      view: function () {
        return { effects: {
          shutterAt: shutterAt.slice(), shutterFrom: shutterFrom.slice(),
          deathAt: deathAt.slice(), sayAt: sayAt.slice(),
          lastSay: lastSay.slice(), aid: aid.slice()
        } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.weeks || (config && config.weeks) || 0;
      parts.push("WEEK " + (state.week || 0) + (total ? " / " + total : ""));
      if (state.variant) parts.push("VARIANT +25%");
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else if (state.seats) {
        var waiting = state.seats.filter(function (s) { return s.pending; });
        parts.push(waiting.length ? "WAITING ON " + waiting.length :
          "DIALS IN");
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(num(seat.score)) +
        "</span>" +
        '<span class="plate-label">' +
        escapeHtml(shortRegion(seat.region || "", true)) + "</span>" +
        (seat.deaths ? '<span class="plate-dead">' + num(seat.deaths) +
          "†</span>" : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.weeks || 0) +
          " of " + (results.maxWeeks || results.weeks || 0) + " weeks";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var gdp = results.gdp || [];
    var deaths = results.deaths || [];
    var regions = results.regions || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " KEPT THE LIGHTS ON" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.weeks || 0) + " WEEK" +
      ((results.weeks || 0) === 1 ? "" : "S") + " · " +
      escapeHtml(num(results.totalDeaths)) + " DEAD" + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">gdp</span>' +
      '<span class="end-head">dead</span>' +
      '<span class="end-head">region</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(num(scores[i]))) +
        cell(escapeHtml(num(gdp[i]))) +
        cell(escapeHtml(num(deaths[i]))) +
        cell(escapeHtml(regions[i] || ""));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  // Aid entries name their recipient by alias; the renderer wants a position.
  function resolveAidPositions(events, regions) {
    var index = {};
    (regions || []).forEach(function (name, pos) { index[name] = pos; });
    events.forEach(function (event) {
      if (event.kind !== "dial") return;
      (event.aid || []).forEach(function (entry) {
        if (typeof entry.toPos !== "number") {
          entry.toPos = index[entry.to];
        }
      });
    });
    return events;
  }

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.posSeat = state.posSeat || [0, 1, 2, 3, 4, 5];
    view.regions = state.regions || [];
    view.edges = state.edges || [];
    view.curves = state.curves || {};
    view.hospitalCap = state.hospitalCap || 25000;
    view.week = state.week || 0;
    view.weeks = state.weeks || 0;
    view.weeksPlayed = state.weeksPlayed || 0;
    view.variant = !!state.variant;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted governor frame becomes a six-seat state so the same scene
  // draws: the seat's own region in full, the others with the public numbers
  // the governor legitimately sees (and no true infection counts anywhere).
  function playerFrameToState(data) {
    if (data.seats) return data;
    var regions = data.regions || [];
    var seats = [];
    var posSeat = [];
    for (var p = 0; p < 6; p++) { posSeat.push(p); }
    function blank(pos) {
      return {
        seat: pos, pos: pos, region: regions[pos] || ("Region " + pos),
        name: regions[pos] || ("Region " + pos),
        score: 0, gdp: 0, deaths: 0, deathsWeek: 0, infected: 0,
        confirmed: 0, alive: 1000000, lockdown: 0, testing: 0, hospital: 0,
        gates: [], aid: [], say: "", heard: [], notes: "", pending: false
      };
    }
    for (var i = 0; i < 6; i++) seats.push(blank(i));
    if (data.own && typeof data.pos === "number") {
      var own = seats[data.pos];
      own.region = data.region;
      own.name = data.region;
      own.gdp = data.own.gdp;
      own.deaths = data.own.deaths;
      own.deathsWeek = data.own.deathsWeek;
      own.confirmed = data.own.confirmed;
      own.infected = data.own.confirmed;
      own.lockdown = data.own.lockdown;
      own.testing = data.own.testing;
      own.score = data.own.score;
      own.gates = data.own.gates || [];
      own.hospital = HOSPITAL_BANDS.indexOf(data.own.hospital);
      if (own.hospital < 0) own.hospital = 0;
      own.notes = data.notes || "";
    }
    (data.others || []).forEach(function (other) {
      var seat = seats[other.pos];
      if (!seat) return;
      seat.region = other.region;
      seat.name = other.region;
      seat.gdp = other.gdp;
      seat.deaths = other.deaths;
      seat.confirmed = other.confirmed;
      seat.infected = other.confirmed;
      seat.lockdown = other.lockdown;
      seat.testing = other.testing;
      seat.score = other.score;
    });
    var edges = [];
    (data.map || []).forEach(function (edge) {
      edges.push({
        a: regions.indexOf(edge.a), b: regions.indexOf(edge.b),
        road: edge.road, eff: 0, flow: 0
      });
    });
    return {
      seats: seats, posSeat: posSeat, regions: regions, edges: edges,
      curves: {}, hospitalCap: 25000, week: data.week, weeks: data.weeks,
      weeksPlayed: data.weeksPlayed, variant: data.variant,
      phase: data.done ? "done" : "dials", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.region; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              var events = resolveAidPositions(latest.events || [],
                latest.regions);
              effects.absorb(events);
              if (options.feed) {
                renderFeed(options.feed, events, nameMap, undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per week, a marker per
  // dial (coloured by the seat) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.week;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "dial" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "dial" ? " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var config = payload.config || {};
    var states = payload.states || [];
    var regions = (states[0] && states[0].regions) || [];
    var events = resolveAidPositions(payload.events || [], regions);
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var speed = 1;   // playback rate; the per-event dwell is stepMs / speed
    var announced = false;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      function togglePlay() {
        playing = !playing;
        if (playing && index >= events.length) setIndex(0, true);
      }
      if (options.playButton) {
        options.playButton.onclick = togglePlay;
        // Speed chips ride in the transport bar next to the play button.
        var chips = [];
        var row = document.createElement("span");
        row.className = "tspeed";
        [0.5, 1, 2].forEach(function (rate) {
          var chip = document.createElement("button");
          chip.type = "button";
          chip.className = "tchip" + (rate === speed ? " on" : "");
          chip.textContent = rate + "×";
          chip.onclick = function () {
            speed = rate;
            chips.forEach(function (c) {
              c.classList.toggle("on", c === chip);
            });
          };
          chips.push(chip);
          row.appendChild(chip);
        });
        options.playButton.parentNode.insertBefore(
          row, options.playButton.nextSibling);
      }
      // Space pauses/resumes, exactly like the play button — but never
      // while the viewer is typing somewhere.
      document.addEventListener("keydown", function (evt) {
        if (evt.code !== "Space" && evt.key !== " ") return;
        var t = evt.target;
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
            t.tagName === "SELECT" || t.isContentEditable)) {
          return;
        }
        evt.preventDefault();   // no page scroll, no double button fire
        togglePlay();
      });

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", week: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a week turn gets
        // read (the stain grows, the strip advances), a dial less so, a
        // message a little longer.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "week" ? 1500 :
          shown && shown.kind === "dial" ? (shown.say ? 900 : 450) :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs / speed) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        // A picture exists NOW, not merely a started rAF loop: the readiness
        // attribute goes up inside the first frame, after draw returns.
        if (!announced) {
          announced = true;
          document.documentElement.setAttribute("data-replay-loaded", "true");
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  window.ContagionRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
