/** Heavy tactical enemy. Feet at y=0, forward is -Z; named pivots are animation sockets. */
export function buildBrute(THREE) {
  const root = new THREE.Group();
  root.name = 'CH_brute';
  const mat = {
    cloth: new THREE.MeshStandardMaterial({ color: 0x393c37, roughness: 0.98 }),
    clothDark: new THREE.MeshStandardMaterial({ color: 0x262a27, roughness: 0.98 }),
    armor: new THREE.MeshStandardMaterial({ color: 0x77715e, roughness: 0.85, metalness: 0.12 }),
    armorEdge: new THREE.MeshStandardMaterial({ color: 0x9d9478, roughness: 0.78, metalness: 0.15 }),
    armorShade: new THREE.MeshStandardMaterial({ color: 0x555343, roughness: 0.9, metalness: 0.1 }),
    metal: new THREE.MeshStandardMaterial({ color: 0x555c5a, roughness: 0.68, metalness: 0.52 }),
    black: new THREE.MeshStandardMaterial({ color: 0x1b2121, roughness: 0.87, metalness: 0.14 }),
    goggles: new THREE.MeshStandardMaterial({ color: 0x4e5b53, roughness: 0.35, metalness: 0.48 }),
    skin: new THREE.MeshStandardMaterial({ color: 0x806d5a, roughness: 0.94 }),
  };
  let count = 0;
  function group(parent, name, xyz) {
    const g = new THREE.Group();
    g.name = name;
    g.position.set(...xyz);
    parent.add(g);
    return g;
  }
  function box(parent, name, size, xyz, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = mesh.receiveShadow = true;
    parent.add(mesh); count++;
    return mesh;
  }

  const body = group(root, 'BodyRoot', [0, 0, 0]);
  const hipL = group(body, 'HipL', [-0.205, 1.015, 0]);
  const hipR = group(body, 'HipR', [0.205, 1.015, 0]);
  const shoulderL = group(body, 'ShoulderL', [-0.424, 1.681, 0]);
  const shoulderR = group(body, 'ShoulderR', [0.424, 1.681, 0]);
  const head = group(body, 'Head', [0, 1.796, 0]);

  // Core frame: tall, broad, and deliberately weighty from every angle.
  box(body, 'Torso fatigue shell', [0.665, 0.692, 0.334], [0, 1.418, 0.027], mat.cloth);
  box(body, 'Torso upper collar', [0.699, 0.100, 0.379], [0, 1.739, 0.005], mat.clothDark);
  box(body, 'Broad pelvis', [0.510, 0.187, 0.308], [0, 1.006, 0.013], mat.clothDark);
  box(body, 'Abdominal lower armor', [0.548, 0.194, 0.091], [0, 1.164, -0.182], mat.armorShade);
  box(body, 'Back armored spine', [0.468, 0.507, 0.091], [0, 1.458, 0.217], mat.armorShade);
  box(body, 'Back spine center ridge', [0.097, 0.431, 0.022], [0, 1.456, 0.274], mat.armor);
  box(body, 'Left chest ballistic plate', [0.289, 0.377, 0.100], [-0.160, 1.526, -0.206], mat.armor);
  box(body, 'Right chest ballistic plate', [0.289, 0.377, 0.100], [0.160, 1.526, -0.206], mat.armor);
  box(body, 'Chest plate center seam', [0.034, 0.366, 0.017], [0, 1.528, -0.264], mat.black);
  box(body, 'Chest plate upper lip', [0.648, 0.036, 0.119], [0, 1.731, -0.206], mat.armorEdge);
  box(body, 'Chest plate lower lip', [0.629, 0.029, 0.123], [0, 1.315, -0.205], mat.armorShade);
  for (const side of [-1, 1]) {
    box(body, `Chest plate side trim ${side}`, [0.030, 0.352, 0.113], [side * 0.323, 1.522, -0.209], mat.armorShade);
    box(body, `Chest inset ${side}`, [0.238, 0.180, 0.011], [side * 0.160, 1.550, -0.262], mat.armorShade);
    box(body, `Chest service tab ${side}`, [0.109, 0.052, 0.017], [side * 0.145, 1.639, -0.268], mat.armorEdge);
    box(body, `Waist side plate ${side}`, [0.062, 0.193, 0.238], [side * 0.333, 1.164, 0.018], mat.armor);
    box(body, `Shoulder strap front ${side}`, [0.078, 0.376, 0.032], [side * 0.276, 1.531, -0.235], mat.black);
    box(body, `Shoulder strap rear ${side}`, [0.081, 0.348, 0.031], [side * 0.278, 1.528, 0.243], mat.black);
  }
  box(body, 'Heavy belt main', [0.560, 0.093, 0.352], [0, 1.073, 0.012], mat.black);
  box(body, 'Belt buckle', [0.117, 0.086, 0.023], [0, 1.071, -0.180], mat.metal);
  box(body, 'Belt buckle inset', [0.074, 0.048, 0.025], [0, 1.070, -0.196], mat.armorShade);
  for (const side of [-1, 1]) {
    box(body, `Belt side pouch ${side}`, [0.148, 0.154, 0.178], [side * 0.275, 1.039, 0.114], mat.armorShade);
    box(body, `Belt side pouch flap ${side}`, [0.156, 0.047, 0.191], [side * 0.275, 1.118, 0.111], mat.armor);
    box(body, `Belt side pouch clasp ${side}`, [0.028, 0.053, 0.015], [side * 0.275, 1.090, -0.004], mat.black);
  }

  // Oversized back plate and field pack create a thick side silhouette.
  box(body, 'Armor back plate', [0.599, 0.487, 0.079], [0, 1.503, 0.249], mat.armor);
  box(body, 'Back plate upper ridge', [0.620, 0.049, 0.104], [0, 1.754, 0.246], mat.armorEdge);
  box(body, 'Back utility pack', [0.405, 0.346, 0.161], [0, 1.448, 0.359], mat.armorShade);
  box(body, 'Pack flap', [0.419, 0.089, 0.176], [0, 1.617, 0.360], mat.armor);
  for (const side of [-1, 1]) {
    box(body, `Pack compression strap ${side}`, [0.045, 0.339, 0.014], [side * 0.154, 1.452, 0.449], mat.black);
    box(body, `Pack side canister ${side}`, [0.091, 0.243, 0.104], [side * 0.257, 1.438, 0.354], mat.black);
    box(body, `Pack side canister top ${side}`, [0.103, 0.035, 0.112], [side * 0.257, 1.566, 0.354], mat.metal);
  }

  // Lower body: massive thigh plates, segmented shins, and broad boots.
  for (const [pivot, side] of [[hipL, -1], [hipR, 1]]) {
    box(pivot, `Thigh fatigues ${side}`, [0.247, 0.456, 0.276], [0, -0.217, 0.010], mat.cloth);
    box(pivot, `Thigh front plate ${side}`, [0.252, 0.313, 0.074], [0, -0.184, -0.160], mat.armor);
    box(pivot, `Thigh plate ridge ${side}`, [0.258, 0.027, 0.082], [0, -0.333, -0.160], mat.armorEdge);
    box(pivot, `Thigh side plate ${side}`, [0.055, 0.286, 0.200], [side * 0.134, -0.207, -0.005], mat.armorShade);
    box(pivot, `Knee pad core ${side}`, [0.222, 0.133, 0.097], [0, -0.496, -0.145], mat.black);
    box(pivot, `Knee ballistic shell ${side}`, [0.207, 0.105, 0.111], [0, -0.492, -0.202], mat.armorEdge);
    box(pivot, `Shin fatigue ${side}`, [0.211, 0.397, 0.230], [0, -0.756, 0.012], mat.clothDark);
    box(pivot, `Shin armor front ${side}`, [0.222, 0.299, 0.075], [0, -0.738, -0.143], mat.armor);
    box(pivot, `Shin armor upper band ${side}`, [0.227, 0.035, 0.086], [0, -0.605, -0.145], mat.armorShade);
    box(pivot, `Boot main ${side}`, [0.237, 0.158, 0.312], [0, -0.936, -0.075], mat.black);
    box(pivot, `Boot toe cap ${side}`, [0.236, 0.102, 0.104], [0, -0.963, -0.196], mat.armorShade);
    box(pivot, `Boot sole ${side}`, [0.258, 0.040, 0.333], [0, -0.995, -0.079], mat.black);
    for (let i = 0; i < 3; i++) box(pivot, `Boot strap ${side}-${i}`, [0.242, 0.027, 0.019], [0, -0.872 - i * 0.038, -0.183], mat.armorShade);
  }

  // Separate arm pivots permit broad swings without moving shoulder armor.
  for (const [pivot, side] of [[shoulderL, -1], [shoulderR, 1]]) {
    box(pivot, `Upper arm fatigues ${side}`, [0.242, 0.362, 0.265], [side * 0.009, -0.164, 0.012], mat.cloth);
    box(pivot, `Pauldron outer shell ${side}`, [0.322, 0.188, 0.333], [side * 0.045, -0.067, -0.005], mat.armor);
    box(pivot, `Pauldron upper lip ${side}`, [0.313, 0.040, 0.350], [side * 0.046, 0.030, -0.006], mat.armorEdge);
    box(pivot, `Pauldron front edge ${side}`, [0.326, 0.160, 0.041], [side * 0.045, -0.065, -0.177], mat.armorShade);
    box(pivot, `Pauldron unit patch ${side}`, [0.013, 0.064, 0.090], [side * 0.209, -0.080, -0.007], mat.black);
    box(pivot, `Upper arm side plate ${side}`, [0.060, 0.171, 0.178], [side * 0.141, -0.245, 0.004], mat.armorShade);
    box(pivot, `Elbow pad ${side}`, [0.229, 0.116, 0.250], [side * 0.007, -0.367, 0.006], mat.black);
    box(pivot, `Forearm fatigues ${side}`, [0.190, 0.234, 0.219], [side * 0.009, -0.489, -0.010], mat.clothDark);
    box(pivot, `Forearm armor ${side}`, [0.201, 0.202, 0.078], [side * 0.009, -0.493, -0.138], mat.armor);
    box(pivot, `Forearm cuff ${side}`, [0.209, 0.054, 0.234], [side * 0.009, -0.597, -0.009], mat.armorShade);
    box(pivot, `Glove ${side}`, [0.180, 0.116, 0.216], [side * 0.009, -0.668, -0.013], mat.black);
    box(pivot, `Glove knuckle guard ${side}`, [0.179, 0.039, 0.088], [side * 0.009, -0.683, -0.112], mat.armorShade);
  }

  // Helmet, sealed jaw guard, and subdued goggles finish the heavy silhouette.
  box(head, 'Neck wrap', [0.289, 0.115, 0.252], [0, 0.015, 0.018], mat.black);
  box(head, 'Head base', [0.267, 0.237, 0.258], [0, 0.126, 0], mat.skin);
  box(head, 'Ballistic helmet dome', [0.339, 0.218, 0.336], [0, 0.217, 0.012], mat.armor);
  box(head, 'Helmet crown', [0.292, 0.045, 0.270], [0, 0.334, 0.015], mat.armorEdge);
  box(head, 'Helmet front brim', [0.360, 0.048, 0.091], [0, 0.222, -0.176], mat.armorShade);
  box(head, 'Helmet rear skirt', [0.322, 0.099, 0.059], [0, 0.107, 0.181], mat.armorShade);
  for (const side of [-1, 1]) {
    box(head, `Helmet side armor ${side}`, [0.066, 0.160, 0.224], [side * 0.166, 0.157, 0.021], mat.armorShade);
    box(head, `Helmet rail ${side}`, [0.022, 0.034, 0.220], [side * 0.204, 0.251, 0.015], mat.black);
    box(head, `Ear cup ${side}`, [0.081, 0.127, 0.146], [side * 0.172, 0.107, 0.031], mat.black);
    box(head, `Ear cup inset ${side}`, [0.013, 0.086, 0.099], [side * 0.219, 0.107, 0.031], mat.metal);
    box(head, `Goggle lens ${side}`, [0.106, 0.071, 0.020], [side * 0.073, 0.190, -0.141], mat.goggles);
  }
  box(head, 'Goggle central bridge', [0.051, 0.043, 0.025], [0, 0.185, -0.149], mat.black);
  box(head, 'Goggle upper band', [0.286, 0.029, 0.025], [0, 0.236, -0.141], mat.black);
  box(head, 'Lower face scarf', [0.290, 0.106, 0.074], [0, 0.079, -0.113], mat.clothDark);
  box(head, 'Jaw plate', [0.226, 0.085, 0.049], [0, 0.061, -0.166], mat.armorShade);
  box(head, 'Jaw vent', [0.107, 0.022, 0.013], [0, 0.071, -0.193], mat.black);

  root.userData.meshCount = count;
  root.userData.description = 'Heavy armored tactical brute';
  return root;
}
