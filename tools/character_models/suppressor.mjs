/** Dark tactical control unit with muted purple gear. Feet at y=0; forward is -Z. */
export function buildSuppressor(THREE) {
  const root = new THREE.Group(); root.name = 'Suppressor';
  const body = new THREE.Group(); body.name = 'BodyRoot'; root.add(body);
  const m = {
    cloth: new THREE.MeshStandardMaterial({ color: 0x30323a, roughness: 0.97 }),
    shade: new THREE.MeshStandardMaterial({ color: 0x22252d, roughness: 0.98 }),
    armor: new THREE.MeshStandardMaterial({ color: 0x484852, roughness: 0.85, metalness: 0.18 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x696777, roughness: 0.74, metalness: 0.25 }),
    purple: new THREE.MeshStandardMaterial({ color: 0x685279, roughness: 0.74, metalness: 0.18 }),
    purpleDark: new THREE.MeshStandardMaterial({ color: 0x44374f, roughness: 0.86, metalness: 0.12 }),
    black: new THREE.MeshStandardMaterial({ color: 0x15191d, roughness: 0.94 }),
    metal: new THREE.MeshStandardMaterial({ color: 0x7c8387, roughness: 0.54, metalness: 0.63 }),
    lens: new THREE.MeshStandardMaterial({ color: 0x5f597a, roughness: 0.31, metalness: 0.41, emissive: 0x130c23 }),
    beacon: new THREE.MeshStandardMaterial({ color: 0x997db5, roughness: 0.55, emissive: 0x2c1642, emissiveIntensity: 0.55 }),
  };
  let meshes = 0;
  function group(parent, name, p) { const g = new THREE.Group(); g.name = name; g.position.set(...p); parent.add(g); return g; }
  function box(parent, name, size, p, material, r) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name; mesh.position.set(...p); if (r) mesh.rotation.set(...r);
    mesh.castShadow = mesh.receiveShadow = true; parent.add(mesh); meshes++; return mesh;
  }

  // Long vest and squared command harness establish a tall, deliberate profile.
  box(body, 'Pelvis fatigues', [0.450, 0.169, 0.281], [0, 0.790, 0.006], m.shade);
  box(body, 'Torso underlayer', [0.498, 0.581, 0.297], [0, 1.172, 0.013], m.cloth);
  box(body, 'Long carrier front', [0.486, 0.462, 0.091], [0, 1.139, -0.181], m.armor);
  box(body, 'Carrier upper yoke', [0.531, 0.105, 0.122], [0, 1.439, -0.172], m.edge);
  box(body, 'Carrier rear', [0.479, 0.425, 0.078], [0, 1.160, 0.198], m.armor);
  box(body, 'Center telemetry plate', [0.124, 0.228, 0.026], [0, 1.213, -0.242], m.black);
  box(body, 'Telemetry vertical glow', [0.023, 0.169, 0.008], [0, 1.226, -0.261], m.beacon);
  box(body, 'Telemetry top indicator', [0.074, 0.023, 0.009], [0, 1.344, -0.263], m.purple);
  box(body, 'Utility belt', [0.510, 0.077, 0.319], [0, 0.845, 0.012], m.black);
  box(body, 'Belt command buckle', [0.095, 0.062, 0.023], [0, 0.847, -0.169], m.metal);
  for (const side of [-1, 1]) {
    box(body, `Purple harness shoulder ${side}`, [0.065, 0.051, 0.356], [side * 0.175, 1.453, 0.012], m.purpleDark);
    box(body, `Carrier side rib ${side}`, [0.039, 0.355, 0.289], [side * 0.265, 1.184, 0.005], m.edge);
    box(body, `Lower armor flap ${side}`, [0.196, 0.153, 0.045], [side * 0.129, 0.936, -0.204], m.purpleDark);
    box(body, `Utility pouch ${side}`, [0.112, 0.143, 0.098], [side * 0.223, 0.864, -0.153], m.shade);
    box(body, `Pouch purple tab ${side}`, [0.039, 0.050, 0.009], [side * 0.223, 0.905, -0.208], m.purple);
    box(body, `Upper chest control pad ${side}`, [0.128, 0.082, 0.021], [side * 0.159, 1.325, -0.242], m.black);
    box(body, `Upper chest control bar ${side}`, [0.079, 0.010, 0.008], [side * 0.159, 1.327, -0.258], m.beacon);
  }
  // Control pack and twin aerials distinguish the unit in rear and side views.
  box(body, 'Signal pack main', [0.381, 0.401, 0.169], [0, 1.192, 0.309], m.black);
  box(body, 'Signal pack upper armor', [0.402, 0.102, 0.180], [0, 1.402, 0.306], m.armor);
  box(body, 'Signal pack rear plate', [0.302, 0.271, 0.030], [0, 1.185, 0.412], m.purpleDark);
  box(body, 'Signal pack center light', [0.065, 0.169, 0.013], [0, 1.188, 0.433], m.beacon);
  for (const side of [-1, 1]) {
    box(body, `Signal coil ${side}`, [0.066, 0.254, 0.118], [side * 0.244, 1.194, 0.314], m.purple);
    box(body, `Signal coil black inset ${side}`, [0.009, 0.158, 0.071], [side * 0.281, 1.194, 0.316], m.black);
    box(body, `Aerial base ${side}`, [0.042, 0.054, 0.042], [side * 0.119, 1.433, 0.314], m.metal);
    box(body, `Aerial shaft ${side}`, [0.015, 0.207, 0.015], [side * 0.119, 1.556, 0.314], m.black);
    box(body, `Aerial tip ${side}`, [0.024, 0.029, 0.024], [side * 0.119, 1.672, 0.314], m.purple);
  }

  // Straight legs with strapped field armor and wide stable boots.
  for (const side of [-1, 1]) {
    const label = side < 0 ? 'L' : 'R';
    const hip = group(body, `Hip${label}`, [side * 0.154, 0.756, 0]);
    box(hip, `Trouser ${label}`, [0.220, 0.414, 0.238], [0, -0.220, 0.011], m.cloth);
    box(hip, `Thigh plate ${label}`, [0.204, 0.250, 0.051], [0, -0.197, -0.136], m.armor);
    box(hip, `Thigh panel ${label}`, [0.125, 0.101, 0.008], [0, -0.190, -0.167], m.purpleDark);
    box(hip, `Thigh utility clip ${label}`, [0.019, 0.045, 0.015], [side * 0.120, -0.243, -0.029], m.metal);
    box(hip, `Knee fabric ${label}`, [0.211, 0.076, 0.219], [0, -0.428, 0.005], m.shade);
    box(hip, `Knee cap ${label}`, [0.204, 0.139, 0.060], [0, -0.466, -0.133], m.edge);
    box(hip, `Knee purple marker ${label}`, [0.102, 0.018, 0.009], [0, -0.460, -0.169], m.purple);
    box(hip, `Lower trouser ${label}`, [0.188, 0.252, 0.224], [0, -0.582, 0.009], m.shade);
    box(hip, `Shin front guard ${label}`, [0.178, 0.176, 0.050], [0, -0.583, -0.128], m.armor);
    box(hip, `Shin vertical stripe ${label}`, [0.027, 0.128, 0.009], [0, -0.584, -0.158], m.purpleDark);
    box(hip, `Boot ankle ${label}`, [0.229, 0.122, 0.253], [0, -0.679, 0.021], m.black);
    box(hip, `Boot toe ${label}`, [0.232, 0.065, 0.324], [0, -0.707, -0.071], m.black);
    box(hip, `Boot sole ${label}`, [0.245, 0.020, 0.342], [0, -0.746, -0.074], m.shade);
    box(hip, `Boot toe cap ${label}`, [0.229, 0.027, 0.085], [0, -0.721, -0.194], m.armor);
  }

  // Boxed forearm control modules and narrower shoulders distinguish from shredder.
  for (const side of [-1, 1]) {
    const label = side < 0 ? 'L' : 'R';
    const arm = group(body, `Shoulder${label}`, [side * 0.360, 1.419, 0]);
    box(arm, `Upper sleeve ${label}`, [0.222, 0.264, 0.232], [0, -0.148, 0], m.cloth);
    box(arm, `Angular shoulder shell ${label}`, [0.272, 0.113, 0.278], [0, -0.040, 0], m.armor);
    box(arm, `Shoulder purple epaulet ${label}`, [0.264, 0.018, 0.264], [0, 0.024, 0], m.purpleDark);
    box(arm, `Shoulder side badge ${label}`, [0.010, 0.061, 0.088], [side * 0.143, -0.078, 0.010], m.purple);
    box(arm, `Elbow cuff ${label}`, [0.202, 0.076, 0.211], [0, -0.295, 0], m.shade);
    box(arm, `Forearm sleeve ${label}`, [0.189, 0.223, 0.207], [0, -0.418, -0.005], m.cloth);
    box(arm, `Forearm control box ${label}`, [0.200, 0.180, 0.074], [0, -0.427, -0.128], m.black);
    box(arm, `Forearm module lid ${label}`, [0.192, 0.037, 0.079], [0, -0.342, -0.128], m.edge);
    box(arm, `Forearm control screen ${label}`, [0.111, 0.067, 0.011], [0, -0.431, -0.172], m.lens);
    box(arm, `Forearm control stripe ${label}`, [0.131, 0.013, 0.011], [0, -0.482, -0.171], m.purple);
    box(arm, `Wrist cuff ${label}`, [0.196, 0.055, 0.215], [0, -0.550, -0.004], m.purpleDark);
    box(arm, `Glove ${label}`, [0.179, 0.112, 0.195], [0, -0.621, -0.018], m.black);
    box(arm, `Glove knuckle shell ${label}`, [0.166, 0.032, 0.070], [0, -0.623, -0.114], m.armor);
    if (side === 1) group(arm, 'WeaponMount', [0, -0.613, -0.128]);
  }

  const head = group(body, 'Head', [0, 1.522, 0]);
  box(head, 'Neck wrap', [0.275, 0.104, 0.263], [0, 0.028, 0.004], m.black);
  box(head, 'Head underhelmet', [0.280, 0.270, 0.266], [0, 0.181, 0.002], m.shade);
  box(head, 'Deep helmet crown', [0.351, 0.194, 0.334], [0, 0.334, 0.013], m.armor);
  box(head, 'Helmet top plate', [0.315, 0.033, 0.290], [0, 0.443, 0.008], m.edge);
  box(head, 'Helmet front shroud', [0.366, 0.054, 0.104], [0, 0.304, -0.163], m.purpleDark);
  box(head, 'Single dark visor', [0.282, 0.102, 0.022], [0, 0.246, -0.146], m.lens);
  box(head, 'Visor purple border', [0.308, 0.020, 0.024], [0, 0.301, -0.152], m.purple);
  box(head, 'Breather face plate', [0.212, 0.118, 0.068], [0, 0.136, -0.144], m.black);
  box(head, 'Breather filter', [0.091, 0.057, 0.025], [0, 0.134, -0.191], m.metal);
  for (const side of [-1, 1]) {
    box(head, `Helmet ear shell ${side}`, [0.060, 0.160, 0.176], [side * 0.172, 0.221, 0.033], m.armor);
    box(head, `Ear antenna plate ${side}`, [0.009, 0.064, 0.089], [side * 0.204, 0.225, 0.027], m.purple);
    box(head, `Jaw strap ${side}`, [0.019, 0.122, 0.028], [side * 0.148, 0.104, -0.083], m.black);
  }

  root.userData.meshCount = meshes;
  root.userData.description = 'Purple-accent tactical suppressor control unit';
  return root;
}
