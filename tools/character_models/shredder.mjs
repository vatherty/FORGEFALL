/** Fast close-range tactical enemy. Feet at y=0; forward is -Z. */
export function buildShredder(THREE) {
  const root = new THREE.Group(); root.name = 'Shredder';
  const body = new THREE.Group(); body.name = 'BodyRoot'; root.add(body);
  const m = {
    cloth: new THREE.MeshStandardMaterial({ color: 0x414240, roughness: 0.98 }),
    shade: new THREE.MeshStandardMaterial({ color: 0x292d2c, roughness: 0.99 }),
    armor: new THREE.MeshStandardMaterial({ color: 0x535b59, roughness: 0.83, metalness: 0.2 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x77817b, roughness: 0.75, metalness: 0.23 }),
    black: new THREE.MeshStandardMaterial({ color: 0x1a1e1e, roughness: 0.95 }),
    red: new THREE.MeshStandardMaterial({ color: 0x8f2925, roughness: 0.69, metalness: 0.1 }),
    redDark: new THREE.MeshStandardMaterial({ color: 0x541e1d, roughness: 0.8 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x858782, roughness: 0.55, metalness: 0.59 }),
    lens: new THREE.MeshStandardMaterial({ color: 0x9a2b20, roughness: 0.35, metalness: 0.38, emissive: 0x310603 }),
  };
  let meshes = 0;
  function group(parent, name, p) { const g = new THREE.Group(); g.name = name; g.position.set(...p); parent.add(g); return g; }
  function box(parent, name, size, p, material, r) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name; mesh.position.set(...p); if (r) mesh.rotation.set(...r);
    mesh.castShadow = mesh.receiveShadow = true; parent.add(mesh); meshes++; return mesh;
  }

  // Lean, forward-leaning plate carrier with visible diagonal assault straps.
  box(body, 'Pelvis fatigues', [0.424, 0.172, 0.275], [0, 0.789, 0], m.shade);
  box(body, 'Narrow combat torso', [0.478, 0.578, 0.294], [0, 1.174, 0.019], m.cloth);
  box(body, 'Chest plate', [0.448, 0.326, 0.072], [0, 1.206, -0.171], m.armor);
  box(body, 'Chest upper armor', [0.481, 0.096, 0.100], [0, 1.424, -0.164], m.edge);
  box(body, 'Lower chest segmentation', [0.454, 0.040, 0.085], [0, 1.018, -0.165], m.black);
  box(body, 'Back plate', [0.434, 0.356, 0.070], [0, 1.190, 0.195], m.armor);
  box(body, 'Assault belt', [0.481, 0.071, 0.315], [0, 0.849, 0.006], m.black);
  box(body, 'Belt buckle', [0.080, 0.052, 0.020], [0, 0.850, -0.163], m.steel);
  for (const side of [-1, 1]) {
    box(body, `Diagonal assault strap ${side}`, [0.045, 0.380, 0.027], [side * 0.117, 1.278, -0.228], m.black, [0, 0, side * 0.31]);
    box(body, `Strap red tab ${side}`, [0.051, 0.060, 0.029], [side * 0.115, 1.360, -0.247], m.red);
    box(body, `Chest plate side ${side}`, [0.032, 0.306, 0.087], [side * 0.232, 1.207, -0.163], m.edge);
    box(body, `Waist ammo pouch ${side}`, [0.115, 0.124, 0.075], [side * 0.170, 0.867, -0.175], m.shade);
    box(body, `Waist pouch pull ${side}`, [0.030, 0.045, 0.008], [side * 0.170, 0.896, -0.217], m.red);
  }
  box(body, 'Slim rear battery pack', [0.298, 0.287, 0.125], [0, 1.197, 0.261], m.black);
  box(body, 'Rear pack central ridge', [0.067, 0.250, 0.017], [0, 1.198, 0.330], m.redDark);
  box(body, 'Rear pack top', [0.316, 0.054, 0.136], [0, 1.355, 0.260], m.armor);
  for (const side of [-1, 1]) box(body, `Rear pack latch ${side}`, [0.024, 0.078, 0.020], [side * 0.119, 1.193, 0.336], m.steel);

  // Long legs and low-profile boots keep the runner silhouette quick and narrow.
  for (const side of [-1, 1]) {
    const label = side < 0 ? 'L' : 'R';
    const hip = group(body, `Hip${label}`, [side * 0.143, 0.755, 0]);
    box(hip, `Trouser ${label}`, [0.213, 0.418, 0.228], [0, -0.221, 0.012], m.cloth);
    box(hip, `Thigh front shell ${label}`, [0.195, 0.236, 0.053], [0, -0.188, -0.130], m.armor);
    box(hip, `Thigh red slash ${label}`, [0.125, 0.022, 0.006], [0, -0.191, -0.163], m.red, [0, 0, side * 0.18]);
    box(hip, `Knee pad ${label}`, [0.193, 0.118, 0.078], [0, -0.445, -0.127], m.edge);
    box(hip, `Knee inset ${label}`, [0.132, 0.063, 0.010], [0, -0.445, -0.171], m.black);
    box(hip, `Lower trouser ${label}`, [0.188, 0.250, 0.216], [0, -0.573, 0.008], m.shade);
    box(hip, `Shin guard ${label}`, [0.161, 0.160, 0.045], [0, -0.585, -0.120], m.armor);
    box(hip, `Shin red marker ${label}`, [0.119, 0.013, 0.006], [0, -0.624, -0.146], m.redDark);
    box(hip, `Ankle boot ${label}`, [0.219, 0.123, 0.246], [0, -0.679, 0.018], m.black);
    box(hip, `Extended boot toe ${label}`, [0.229, 0.067, 0.325], [0, -0.706, -0.067], m.black);
    box(hip, `Boot sole ${label}`, [0.239, 0.022, 0.342], [0, -0.744, -0.073], m.shade);
    box(hip, `Boot toe armor ${label}`, [0.225, 0.027, 0.090], [0, -0.721, -0.192], m.armor);
  }

  // Aggressive angular pauldrons and light blades on forearms.
  for (const side of [-1, 1]) {
    const label = side < 0 ? 'L' : 'R';
    const arm = group(body, `Shoulder${label}`, [side * 0.343, 1.403, 0]);
    box(arm, `Upper sleeve ${label}`, [0.209, 0.266, 0.221], [0, -0.153, 0], m.cloth);
    box(arm, `Angled pauldron ${label}`, [0.280, 0.152, 0.300], [side * 0.021, -0.061, -0.015], m.armor, [0, 0, side * 0.10]);
    box(arm, `Pauldron top ridge ${label}`, [0.263, 0.022, 0.289], [side * 0.021, 0.021, -0.015], m.edge);
    box(arm, `Pauldron red band ${label}`, [0.274, 0.027, 0.027], [side * 0.021, -0.058, -0.169], m.red);
    box(arm, `Elbow pad ${label}`, [0.198, 0.087, 0.219], [0, -0.314, 0], m.black);
    box(arm, `Forearm sleeve ${label}`, [0.181, 0.232, 0.206], [0, -0.439, -0.004], m.shade);
    box(arm, `Forearm shell ${label}`, [0.192, 0.204, 0.057], [0, -0.441, -0.119], m.armor);
    box(arm, `Forearm strike rail ${label}`, [0.096, 0.025, 0.066], [0, -0.438, -0.161], m.steel);
    box(arm, `Wrist cuff ${label}`, [0.191, 0.052, 0.219], [0, -0.565, -0.004], m.redDark);
    box(arm, `Glove ${label}`, [0.175, 0.115, 0.190], [0, -0.635, -0.019], m.black);
    box(arm, `Knuckle guards ${label}`, [0.169, 0.028, 0.059], [0, -0.644, -0.112], m.armor);
    if (side === 1) group(arm, 'WeaponMount', [0, -0.619, -0.133]);
  }

  const head = group(body, 'Head', [0, 1.497, 0]);
  box(head, 'Neck guard', [0.268, 0.092, 0.257], [0, 0.026, 0.005], m.black);
  box(head, 'Face shell', [0.276, 0.269, 0.263], [0, 0.181, 0], m.shade);
  box(head, 'Low profile helmet', [0.335, 0.174, 0.322], [0, 0.341, 0.007], m.armor);
  box(head, 'Helmet crest', [0.100, 0.037, 0.240], [0, 0.447, 0.002], m.redDark);
  box(head, 'Helmet front brow', [0.359, 0.041, 0.095], [0, 0.315, -0.156], m.edge);
  box(head, 'Full assault visor', [0.276, 0.092, 0.022], [0, 0.258, -0.149], m.lens);
  box(head, 'Visor central slash', [0.037, 0.090, 0.006], [0, 0.259, -0.163], m.black);
  box(head, 'Lower respirator', [0.215, 0.102, 0.066], [0, 0.150, -0.143], m.black);
  box(head, 'Respirator red intake', [0.103, 0.019, 0.010], [0, 0.149, -0.180], m.red);
  for (const side of [-1, 1]) {
    box(head, `Helmet ear shell ${side}`, [0.051, 0.133, 0.167], [side * 0.164, 0.230, 0.035], m.armor);
    box(head, `Ear vent ${side}`, [0.007, 0.055, 0.082], [side * 0.191, 0.222, 0.034], m.black);
  }

  root.userData.meshCount = meshes;
  root.userData.description = 'Close-range red-accent tactical shredder';
  return root;
}
