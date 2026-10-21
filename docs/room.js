// The room, rebuilt in Three.js from the Mac app's SceneKit scene (same layout, in meters).
// It renders only while something moves (the record, the tonearm) and sits idle otherwise.
import * as THREE from "three";
import * as tex from "./textures.js";

const DESK = 0.74;
const WALL_Z = -0.62;
const PANEL_TOP = DESK + 0.083;
const RECORD_CENTER = new THREE.Vector3(-0.06, PANEL_TOP + 0.0255, -0.12);
const RECORD_R = 0.15;
const PLINTH_FRONT = -0.12 + 0.19;
const CAMERA_POS = new THREE.Vector3(0, 1.13, 1.8);
const CAMERA_TARGET = new THREE.Vector3(0, 1.05, -0.3);
const FOV = 33;
const SLEEVE = 0.315;
const COVER = 0.17, PITCH = 0.192, ROWS = 4, WALL_TOP = 1.6;
export const STACK_LIMIT = 7;
const LAMP = new THREE.Vector3(0.9, DESK, -0.48);
const BUTTONS = ["previous", "playPause", "next"];
const BUTTON_X = [0.09, 0.14, 0.19], BUTTON_Y = DESK + 0.036, BUTTON_R = 0.016;

const OMEGA = (2 * Math.PI * (100 / 3)) / 60; // 33⅓ RPM in rad/s
const SPIN_UP = 0.9, SPIN_DOWN = 1.6;          // seconds
const FRAME_INTERVAL = 1000 / 30;

// Tonearm geometry in the record's plane (u = x, v = -z), relative to the record center.
const PIVOT = { u: RECORD_R * 1.08, v: RECORD_R * 0.78 };
const ARM_LENGTH = RECORD_R * 1.2;
function armAngle(radiusFraction) {
  const target = RECORD_R * radiusFraction;
  let lo = Math.atan2(-PIVOT.v, -PIVOT.u), hi = -Math.PI / 2;
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    const tu = PIVOT.u + ARM_LENGTH * Math.cos(mid), tv = PIVOT.v + ARM_LENGTH * Math.sin(mid);
    if (Math.hypot(tu, tv) < target) lo = mid; else hi = mid;
  }
  return (lo + hi) / 2;
}
const ARM_REST = -Math.PI / 2 + 0.06;
const ARM_START = armAngle(tex.OUTER_GROOVE - 0.01);
const ARM_END = armAngle(tex.INNER_GROOVE + 0.01);

const srgb = (t) => { t.colorSpace = THREE.SRGBColorSpace; return t; };
const std = (opts) => new THREE.MeshStandardMaterial(opts);

export class Room {
  constructor(canvas) {
    this.canvas = canvas;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.0;
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x1a0f0a);
    this.camera = new THREE.PerspectiveCamera(FOV, 1, 0.1, 20);
    this.camera.position.copy(CAMERA_POS);
    this.camera.lookAt(CAMERA_TARGET);

    this.loader = new THREE.TextureLoader();
    this.loader.setCrossOrigin("anonymous");
    this.textureCache = new Map();

    this.materials = this.makeMaterials();
    this.buildRoom();
    this.buildTurntable();
    this.buildLamp();
    this.buildLights();
    this.stand = new THREE.Group();
    this.stack = new THREE.Group();
    this.coverWall = new THREE.Group();
    this.scene.add(this.stand, this.stack, this.coverWall);

    this.wall = [];
    this.stackAlbums = [];
    this.nowPlaying = null;
    this.playback = { playing: false, position: 0, duration: 0, at: performance.now() };
    this.spinVelocity = 0;
    this.armAngle = ARM_REST;
    this.lastFrame = 0;
    this.running = false;

    this.raycaster = new THREE.Raycaster();
    canvas.addEventListener("pointermove", (e) => this.onPointer(e, false));
    canvas.addEventListener("pointerdown", (e) => this.onPointer(e, true));
    canvas.addEventListener("pointerup", () => this.releaseButton());
    canvas.addEventListener("pointerleave", () => this.releaseButton());
    new ResizeObserver(() => this.resize()).observe(canvas);

    this.setNowPlaying(null);
    this.buildStand();
    this.resize();
  }

  // --- Public API -----------------------------------------------------------

  /** Album cover URLs for the back wall, most played first. */
  setWall(urls) {
    this.wall = urls;
    this.buildCoverWall();
    this.requestRender();
  }

  /** Recently finished album cover URLs, newest first. */
  setStack(urls) {
    this.stackAlbums = urls.slice(0, STACK_LIMIT);
    this.buildStack();
    this.requestRender();
  }

  /** The current track ({ art, title, artist }) or null when nothing is playing. */
  async setNowPlaying(track) {
    const art = track?.art ?? null;
    tex.trackLabel(this.labelCanvas, track?.title ?? "", track?.artist ?? "");
    this.labelTexture.needsUpdate = true;
    if (art !== this.nowPlaying?.art || !this.recordTexture) {
      const image = art ? await this.loadImage(art).catch(() => null) : null;
      if (art !== (track?.art ?? null)) return;
      this.recordTexture?.dispose();
      this.recordTexture = srgb(new THREE.CanvasTexture(tex.record(1024, image)));
      this.recordTexture.anisotropy = 8;
      this.record.material.map = this.recordTexture;
      this.record.material.needsUpdate = true;
    }
    const standChanged = art !== this.nowPlaying?.art;
    this.nowPlaying = track;
    if (standChanged) this.buildStand();
    this.requestRender();
  }

  /** playing: bool, position/duration in ms, sampled now. */
  setPlayback({ playing, position, duration }) {
    this.playback = { playing, position, duration, at: performance.now() };
    this.setButtonFace(1, playing ? "pause" : "play");
    this.requestRender();
  }

  /** Called with "previous" | "playPause" | "next". */
  onButton(handler) { this.buttonHandler = handler; }

  // --- Materials & textures -------------------------------------------------

  makeMaterials() {
    const repeat = (canvas, x, y) => {
      const t = srgb(new THREE.CanvasTexture(canvas));
      t.wrapS = t.wrapT = THREE.RepeatWrapping;
      t.repeat.set(x, y);
      t.anisotropy = 8;
      return t;
    };
    return {
      wall: std({ map: repeat(tex.plaster(512, [0.8, 0.7, 0.6], 0.035, 0.02, 3), 6, 3.3), roughness: 0.95 }),
      desk: std({ map: repeat(tex.wood(1024, [0.26, 0.11, 0.05], [0.52, 0.26, 0.12], 0.11, 1), 5, 2.6), roughness: 0.6 }),
      walnut: std({ map: repeat(tex.wood(512, [0.13, 0.07, 0.04], [0.3, 0.17, 0.09], 0.2, 2), 1, 1), roughness: 0.45 }),
      panel: std({ color: new THREE.Color().setRGB(0.72, 0.68, 0.6, THREE.SRGBColorSpace), roughness: 0.55 }),
      aluminum: std({ color: 0xc6c6c2, roughness: 0.3, metalness: 0.6 }),
      black: std({ color: 0x080808, roughness: 0.4 }),
      brass: std({ color: 0xcc9e5c, roughness: 0.32, metalness: 0.6 }),
      bronze: std({ color: new THREE.Color().setRGB(0.055, 0.042, 0.026, THREE.SRGBColorSpace), roughness: 0.36, metalness: 0.2 }),
      cardboard: std({ color: new THREE.Color().setRGB(0.86, 0.82, 0.74, THREE.SRGBColorSpace), roughness: 0.85 }),
      blankSleeve: std({ color: new THREE.Color().setRGB(0.88, 0.85, 0.78, THREE.SRGBColorSpace), roughness: 0.8 }),
    };
  }

  loadImage(url) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.crossOrigin = "anonymous";
      img.onload = () => resolve(img);
      img.onerror = reject;
      img.src = url;
    });
  }

  /** Material showing a cover; fills in when the image arrives. */
  coverMaterial(url) {
    if (!url) return this.materials.blankSleeve;
    let texture = this.textureCache.get(url);
    if (!texture) {
      texture = srgb(this.loader.load(url, () => this.requestRender()));
      texture.anisotropy = 4;
      this.textureCache.set(url, texture);
      if (this.textureCache.size > 120) {
        const [oldest] = this.textureCache.keys();
        this.textureCache.get(oldest).dispose();
        this.textureCache.delete(oldest);
      }
    }
    return std({ map: texture, roughness: 0.5 });
  }

  sleeve(url, w, h, d, artFace) {
    const faces = Array(6).fill(this.materials.cardboard);
    faces[artFace] = this.coverMaterial(url);
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), faces);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    return mesh;
  }

  mesh(geometry, material, { cast = true, receive = true } = {}) {
    const m = new THREE.Mesh(geometry, material);
    m.castShadow = cast;
    m.receiveShadow = receive;
    return m;
  }

  // --- Room -----------------------------------------------------------------

  buildRoom() {
    const wall = this.mesh(new THREE.PlaneGeometry(9, 5), this.materials.wall, { cast: false });
    wall.position.set(0, 2.2, WALL_Z);
    const desk = this.mesh(new THREE.BoxGeometry(5, 0.04, 2.6), this.materials.desk, { cast: false });
    desk.position.set(0, DESK - 0.02, WALL_Z + 1.3);
    this.scene.add(wall, desk);
  }

  buildTurntable() {
    const m = this.materials;
    const group = new THREE.Group();
    const plinth = this.mesh(new THREE.BoxGeometry(0.5, 0.075, 0.38), m.walnut);
    plinth.position.set(0, DESK + 0.0375, -0.12);
    const panel = this.mesh(new THREE.BoxGeometry(0.486, 0.008, 0.366), m.panel);
    panel.position.set(0, PANEL_TOP - 0.004, -0.12);
    const platter = this.mesh(new THREE.CylinderGeometry(0.152, 0.152, 0.022, 96), [m.aluminum, m.black, m.black]);
    platter.position.set(RECORD_CENTER.x, PANEL_TOP + 0.011, RECORD_CENTER.z);
    group.add(plinth, panel, platter);

    // The record: one textured disc that spins.
    this.record = this.mesh(new THREE.CircleGeometry(RECORD_R, 128), std({ roughness: 0.35, metalness: 0.1 }), { cast: false });
    this.record.rotation.x = -Math.PI / 2;
    this.record.position.copy(RECORD_CENTER);
    group.add(this.record);

    // Tonearm: static post, rotating arm.
    const pivot = new THREE.Vector3(RECORD_CENTER.x + PIVOT.u, 0, RECORD_CENTER.z - PIVOT.v);
    const post = this.mesh(new THREE.CylinderGeometry(0.02, 0.02, 0.026, 32), m.black);
    post.position.set(pivot.x, PANEL_TOP + 0.013, pivot.z);
    const collar = this.mesh(new THREE.CylinderGeometry(0.011, 0.011, 0.008, 24), m.aluminum);
    collar.position.set(pivot.x, PANEL_TOP + 0.03, pivot.z);
    group.add(post, collar);

    this.arm = new THREE.Group();
    this.arm.position.set(pivot.x, PANEL_TOP + 0.034, pivot.z);
    const tubeFrom = -0.14 * RECORD_R, tubeTo = ARM_LENGTH - 0.1 * RECORD_R;
    const tube = this.mesh(new THREE.CylinderGeometry(0.0022, 0.0022, tubeTo - tubeFrom, 12), m.aluminum);
    tube.rotation.z = Math.PI / 2;
    tube.position.x = (tubeFrom + tubeTo) / 2;
    const weight = this.mesh(new THREE.CylinderGeometry(0.0095, 0.0095, 0.022, 24), m.black);
    weight.rotation.z = Math.PI / 2;
    weight.position.x = -0.205 * RECORD_R;
    const head = this.mesh(new THREE.BoxGeometry(0.024, 0.006, 0.012), m.black);
    head.position.set(ARM_LENGTH - 0.04 * RECORD_R, -0.004, 0);
    this.arm.add(tube, weight, head);
    this.arm.rotation.y = ARM_REST;
    group.add(this.arm);

    // Transport buttons on the front face.
    this.buttonFaces = {};
    this.buttons = BUTTON_X.map((x, i) => {
      const face = std({ map: this.buttonTexture(i === 0 ? "previous" : i === 2 ? "next" : "play"), roughness: 0.35 });
      const cap = this.mesh(new THREE.CylinderGeometry(BUTTON_R, BUTTON_R, 0.008, 40), [face, face, m.black]);
      cap.rotation.x = Math.PI / 2;
      cap.position.set(x, BUTTON_Y, PLINTH_FRONT + 0.004);
      cap.userData.button = BUTTONS[i];
      const bezel = this.mesh(new THREE.CylinderGeometry(BUTTON_R + 0.003, BUTTON_R + 0.003, 0.002, 40), m.black);
      bezel.rotation.x = Math.PI / 2;
      bezel.position.set(x, BUTTON_Y, PLINTH_FRONT + 0.0005);
      group.add(cap, bezel);
      return cap;
    });

    // Song and artist printed left of the buttons.
    this.labelCanvas = document.createElement("canvas");
    this.labelCanvas.width = 1024;
    this.labelCanvas.height = 144;
    this.labelTexture = srgb(new THREE.CanvasTexture(this.labelCanvas));
    this.labelTexture.anisotropy = 8;
    const label = new THREE.Mesh(new THREE.PlaneGeometry(0.285, 0.04),
      new THREE.MeshBasicMaterial({ map: this.labelTexture, transparent: true, color: 0xdddddd }));
    label.position.set(-0.0825, BUTTON_Y, PLINTH_FRONT + 0.0012);
    group.add(label);

    const knob = this.mesh(new THREE.CylinderGeometry(0.011, 0.011, 0.012, 24), m.brass);
    knob.position.set(0.2, PANEL_TOP + 0.006, 0.02);
    group.add(knob);
    this.scene.add(group);
  }

  buttonTexture(kind, pressed = false) {
    const key = kind + pressed;
    if (!this.buttonFaces[key]) {
      const t = srgb(new THREE.CanvasTexture(tex.buttonFace(kind, pressed)));
      t.center.set(0.5, 0.5);
      t.rotation = Math.PI / 2; // the cap is turned to face the camera; turn the symbol back upright
      this.buttonFaces[key] = t;
    }
    return this.buttonFaces[key];
  }

  setButtonFace(index, kind, pressed = false) {
    const material = this.buttons[index].material[1];
    material.map = this.buttonTexture(kind, pressed);
    material.needsUpdate = true;
    this.buttons[index].userData.kind = kind;
  }

  // --- Sleeves --------------------------------------------------------------

  buildStand() {
    this.disposeGroup(this.stand);
    this.stand.position.set(-0.62, DESK, -0.46);
    this.stand.rotation.y = 0.22;
    const ledge = this.mesh(new THREE.BoxGeometry(0.37, 0.028, 0.08), this.materials.walnut);
    ledge.position.y = 0.014;
    const lean = 0.13;
    const sleeve = this.sleeve(this.nowPlaying?.art, SLEEVE, SLEEVE, 0.004, 4);
    sleeve.rotation.x = -lean;
    sleeve.position.set(0, 0.022 + (SLEEVE / 2) * Math.cos(lean), -0.01 - (SLEEVE / 2) * Math.sin(lean));
    this.stand.add(ledge, sleeve);
  }

  buildStack() {
    this.disposeGroup(this.stack);
    this.stack.position.set(0.56, DESK, -0.16);
    this.stack.rotation.y = -0.12;
    let seed = 7;
    const jitter = (range) => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296 * 2 - 1) * range;
    const albums = [...this.stackAlbums].reverse(); // bottom first
    albums.forEach((url, i) => {
      const sleeve = this.sleeve(url, SLEEVE, 0.0034, SLEEVE, 2);
      const neat = i === albums.length - 1; // the newest sits square on top
      sleeve.position.set(neat ? 0 : jitter(0.015), 0.0017 + i * 0.0036, neat ? 0 : jitter(0.015));
      sleeve.rotation.y = neat ? 0 : jitter(0.14);
      this.stack.add(sleeve);
    });
  }

  /** Covers in rows on the back wall, skipping slots the lamp or stand would hide. */
  buildCoverWall() {
    this.disposeGroup(this.coverWall);
    const distance = CAMERA_POS.z - WALL_Z;
    const halfHeight = distance * Math.tan((this.camera.fov / 2) * Math.PI / 180);
    const columns = Math.max(3, Math.floor((halfHeight * 2 * this.camera.aspect - 0.25) / PITCH));

    this.camera.updateMatrixWorld();
    const screenBox = (min, max) => {
      const box = new THREE.Box2();
      for (const x of [min.x, max.x]) for (const y of [min.y, max.y]) for (const z of [min.z, max.z]) {
        const p = new THREE.Vector3(x, y, z).project(this.camera);
        box.expandByPoint(new THREE.Vector2(p.x, p.y));
      }
      return box;
    };
    const occluders = [
      screenBox(new THREE.Vector3(LAMP.x - 0.11, DESK, LAMP.z - 0.11), new THREE.Vector3(LAMP.x + 0.11, DESK + 0.48, LAMP.z + 0.11)),
      screenBox(new THREE.Vector3(-0.84, DESK, -0.56), new THREE.Vector3(-0.4, DESK + 0.36, -0.36)),
    ];
    const z = WALL_Z + 0.014, half = COVER / 2;
    const slots = [];
    for (let row = 0; row < ROWS; row++) {
      for (let c = 0; c < columns; c++) {
        const x = (c - (columns - 1) / 2) * PITCH, y = WALL_TOP - row * PITCH;
        const box = screenBox(new THREE.Vector3(x - half, y - half, z), new THREE.Vector3(x + half, y + half, z));
        if (!occluders.some((o) => o.intersectsBox(box))) slots.push([x, y, z]);
      }
    }
    this.wall.slice(0, slots.length).forEach((url, i) => {
      const cover = this.sleeve(url, COVER, COVER, 0.006, 4);
      cover.position.set(...slots[i]);
      this.coverWall.add(cover);
    });
  }

  disposeGroup(group) {
    for (const child of [...group.children]) {
      child.geometry?.dispose();
      const materials = Array.isArray(child.material) ? child.material : [child.material];
      for (const material of materials) {
        if (material && !Object.values(this.materials).includes(material)) material.dispose();
      }
      group.remove(child);
    }
  }

  // --- Lamp & lights --------------------------------------------------------

  buildLamp() {
    const group = new THREE.Group();
    group.position.copy(LAMP);
    const bronze = this.materials.bronze;
    const add = (geometry, y) => {
      const m = this.mesh(geometry, bronze);
      m.position.y = y;
      group.add(m);
    };
    add(new THREE.CylinderGeometry(0.072, 0.072, 0.008, 48), 0.004);
    const torus = new THREE.TorusGeometry(0.064, 0.008, 12, 48);
    torus.rotateX(Math.PI / 2);
    add(torus, 0.01);
    add(new THREE.CylinderGeometry(0.024, 0.062, 0.035, 48), 0.026);
    add(new THREE.CylinderGeometry(0.026, 0.026, 0.012, 32), 0.048);
    add(new THREE.CylinderGeometry(0.013, 0.02, 0.03, 24), 0.069);
    add(new THREE.CylinderGeometry(0.013, 0.013, 0.16, 24), 0.16);
    const collar = new THREE.TorusGeometry(0.016, 0.005, 10, 32);
    collar.rotateX(Math.PI / 2);
    add(collar, 0.15);
    add(new THREE.CylinderGeometry(0.024, 0.013, 0.03, 24), 0.255);
    add(new THREE.CylinderGeometry(0.024, 0.024, 0.008, 32), 0.274);
    add(new THREE.CylinderGeometry(0.016, 0.016, 0.03, 24), 0.292);
    add(new THREE.SphereGeometry(0.011, 16, 12), 0.458);

    // Dome shade: a short skirt curving up into a dome, evenly spaced so the glass isn't stretched.
    const rimY = 0.315, skirtTop = 0.345, topY = 0.452, rim = 0.095, skirt = 0.092;
    const raw = [new THREE.Vector2(rim, rimY)];
    for (let i = 24; i >= 0; i--) {
      const theta = (Math.PI / 2) * (i / 24);
      raw.push(new THREE.Vector2(skirt * Math.sin(theta) + 0.004, skirtTop + (topY - skirtTop) * Math.cos(theta)));
    }
    const curve = new THREE.SplineCurve(raw);
    const profile = curve.getSpacedPoints(48);
    const glass = new THREE.MeshBasicMaterial({ map: srgb(new THREE.CanvasTexture(tex.stainedGlass())), side: THREE.DoubleSide });
    glass.color.setScalar(1.25); // lit from inside
    const shade = new THREE.Mesh(new THREE.LatheGeometry(profile, 96), glass);
    group.add(shade);
    this.scene.add(group);
  }

  buildLights() {
    this.scene.add(new THREE.AmbientLight(0xffd2a8, 0.28));

    const spot = (color, intensity, position, target, angleDeg, penumbra, shadowSize) => {
      const light = new THREE.SpotLight(color, intensity, 0, (angleDeg / 2) * Math.PI / 180, penumbra, 2);
      light.position.copy(position);
      light.target.position.copy(target);
      if (shadowSize) {
        light.castShadow = true;
        light.shadow.mapSize.set(shadowSize, shadowSize);
        light.shadow.bias = -0.0004;
        light.shadow.radius = 4;
      }
      this.scene.add(light, light.target);
      return light;
    };
    // Warm key light from the upper left, like low evening sun.
    spot(0xffcc94, 55, new THREE.Vector3(-2.6, 2.9, 1.6), new THREE.Vector3(0.1, 0.95, -0.45), 62, 0.6, 2048);
    // Soft wash over the cover wall.
    spot(0xffd29e, 12, new THREE.Vector3(0.2, 2.6, 0.7), new THREE.Vector3(0, 1.3, WALL_Z), 100, 0.8, 1024);
    // The Tiffany lamp: light pours out of the open bottom of the shade.
    const bulb = LAMP.clone().add(new THREE.Vector3(0, 0.33, 0));
    spot(0xffb866, 0.9, bulb, bulb.clone().add(new THREE.Vector3(0, -1, 0)), 150, 0.5, 512).shadow.camera.near = 0.02;
    const glow = new THREE.PointLight(0xf2e0b8, 0.08, 0.6, 2);
    glow.position.copy(bulb).add(new THREE.Vector3(0, 0.03, 0.14));
    this.scene.add(glow);
  }

  // --- Interaction ----------------------------------------------------------

  buttonAt(event) {
    const rect = this.canvas.getBoundingClientRect();
    const pointer = new THREE.Vector2(((event.clientX - rect.left) / rect.width) * 2 - 1,
                                      -((event.clientY - rect.top) / rect.height) * 2 + 1);
    this.raycaster.setFromCamera(pointer, this.camera);
    return this.raycaster.intersectObjects(this.buttons)[0]?.object ?? null;
  }

  onPointer(event, down) {
    const hit = this.buttonAt(event);
    this.canvas.style.cursor = hit ? "pointer" : "";
    if (!down || !hit) return;
    const index = this.buttons.indexOf(hit);
    const kind = hit.userData.kind ?? BUTTONS[index];
    this.pressed = { index, kind };
    this.setButtonFace(index, index === 1 ? (this.playback.playing ? "pause" : "play") : kind, true);
    this.requestRender();
    this.buttonHandler?.(BUTTONS[index]);
  }

  releaseButton() {
    if (!this.pressed) return;
    const { index } = this.pressed;
    this.pressed = null;
    this.setButtonFace(index, index === 0 ? "previous" : index === 2 ? "next" : this.playback.playing ? "pause" : "play");
    this.requestRender();
  }

  // --- Rendering ------------------------------------------------------------

  resize() {
    const { clientWidth: w, clientHeight: h } = this.canvas;
    if (!w || !h) return;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    // Keep the whole desk (lamp to stand) in view on narrower windows by widening the lens.
    const halfWidthNeeded = Math.atan(1.12 / (CAMERA_POS.z - LAMP.z));
    const fitFov = (2 * Math.atan(Math.tan(halfWidthNeeded) / this.camera.aspect) * 180) / Math.PI;
    this.camera.fov = Math.min(Math.max(FOV, fitFov), 75);
    this.camera.updateProjectionMatrix();
    this.buildCoverWall();
    this.requestRender();
  }

  requestRender() {
    if (this.running) return;
    this.running = true;
    this.lastTick = performance.now();
    requestAnimationFrame((t) => this.tick(t));
  }

  tick(now) {
    const dt = Math.min((now - this.lastTick) / 1000, 0.1);
    this.lastTick = now;

    // Spin up/down with constant acceleration, like the Mac app.
    const { playing, position, duration, at } = this.playback;
    const target = playing ? OMEGA : 0;
    const accel = playing ? OMEGA / SPIN_UP : OMEGA / SPIN_DOWN;
    this.spinVelocity += Math.sign(target - this.spinVelocity) * Math.min(Math.abs(target - this.spinVelocity), accel * dt);
    this.record.rotation.z -= this.spinVelocity * dt; // clockwise seen from above

    // Tonearm follows the track; glides when it jumps.
    let armTarget = ARM_REST;
    if (duration > 0) {
      const elapsed = playing ? now - at : 0;
      const progress = Math.min(Math.max((position + elapsed) / duration, 0), 1);
      armTarget = ARM_START + (ARM_END - ARM_START) * progress;
    }
    const armDelta = armTarget - this.armAngle;
    this.armAngle += Math.abs(armDelta) < 0.0005 ? armDelta : armDelta * Math.min(1, dt * 4);
    this.arm.rotation.y = this.armAngle;

    const moving = this.spinVelocity > 0 || Math.abs(armTarget - this.armAngle) > 0.0005 || playing;
    if (now - this.lastFrame >= FRAME_INTERVAL || !moving) {
      this.renderer.render(this.scene, this.camera);
      this.lastFrame = now;
    }
    if (moving) {
      requestAnimationFrame((t) => this.tick(t));
    } else {
      this.running = false;
    }
  }
}
