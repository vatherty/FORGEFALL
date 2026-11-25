// P9 Sidearm: compact late-2000s service pistol, deliberately chunky and
// faceted so it belongs beside FORGEFALL's voxel rifles. Forward is -Z.
export function buildP9(THREE) {
  const gun = new THREE.Group();
  gun.name = 'P9 Sidearm';
  const materials = {
    slide: new THREE.MeshStandardMaterial({ color: 0x414b4b, roughness: 0.65, metalness: 0.52 }),
    slideTop: new THREE.MeshStandardMaterial({ color: 0x252e30, roughness: 0.72, metalness: 0.43 }),
    bevel: new THREE.MeshStandardMaterial({ color: 0x626a68, roughness: 0.61, metalness: 0.44 }),
    frame: new THREE.MeshStandardMaterial({ color: 0x393d36, roughness: 0.94, metalness: 0.05 }),
    grip: new THREE.MeshStandardMaterial({ color: 0x4b4d40, roughness: 0.98, metalness: 0.02 }),
    gripAccent: new THREE.MeshStandardMaterial({ color: 0x66674f, roughness: 0.96, metalness: 0.02 }),
    black: new THREE.MeshStandardMaterial({ color: 0x171d1e, roughness: 0.86, metalness: 0.24 }),
    bore: new THREE.MeshStandardMaterial({ color: 0x090e0f, roughness: 0.88 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x8b9087, roughness: 0.52, metalness: 0.58 }),
    sight: new THREE.MeshStandardMaterial({ color: 0x9cc986, emissive: 0x244524, emissiveIntensity: 0.55, roughness: 0.6 }),
  };
  function box(name, size, pos, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), materials[material]);
    mesh.name = name;
    mesh.position.set(...pos);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    gun.add(mesh);
    return mesh;
  }
  function anchor(name, pos) {
    const node = new THREE.Object3D();
    node.name = name;
    node.position.set(...pos);
    gun.add(node);
  }

  // Layered slide. The shallow top cap and lower lips give depth from the
  // player's right-hand first-person perspective without smoothing the voxels.
  box('slide slab', [0.061, 0.049, 0.213], [0, 0.018, -0.101], 'slide');
  box('slide top cap', [0.054, 0.012, 0.207], [0, 0.049, -0.101], 'slideTop');
  box('slide left lower rail', [0.005, 0.007, 0.181], [-0.03, -0.011, -0.105], 'bevel');
  box('slide right lower rail', [0.005, 0.007, 0.181], [0.03, -0.011, -0.105], 'bevel');
  box('slide front bevel', [0.057, 0.045, 0.012], [0, 0.018, -0.215], 'bevel');
  box('slide rear cap', [0.059, 0.05, 0.012], [0, 0.018, 0.009], 'slideTop');
  box('slide dust line left', [0.003, 0.004, 0.169], [-0.032, 0.036, -0.108], 'steel');
  box('slide dust line right', [0.003, 0.004, 0.169], [0.032, 0.036, -0.108], 'steel');
  // Serrations are side-facing grooves, visible while the weapon recoils.
  for (const side of [-1, 1]) {
    for (let i = 0; i < 5; i++) {
      box(`rear slide serration ${side} ${i}`, [0.003, 0.034, 0.005], [side * 0.031, 0.019, -0.004 - i * 0.011], 'black', [0, 0, -0.16]);
    }
    for (let i = 0; i < 3; i++) {
      box(`front slide serration ${side} ${i}`, [0.003, 0.026, 0.004], [side * 0.031, 0.02, -0.168 - i * 0.011], 'black', [0, 0, -0.16]);
    }
  }
  box('chamber hood', [0.041, 0.003, 0.045], [0, 0.055, -0.09], 'steel');
  box('ejection port well', [0.035, 0.003, 0.043], [0.009, 0.056, -0.09], 'black');
  box('ejection port forward lip', [0.043, 0.005, 0.004], [0.009, 0.057, -0.114], 'bevel');
  box('ejection port aft lip', [0.043, 0.005, 0.004], [0.009, 0.057, -0.066], 'bevel');
  box('extractor inset', [0.003, 0.005, 0.026], [0.032, 0.031, -0.092], 'steel');

  // Muzzle is square on the outside, with a recessed bore and a distinct
  // recoil spring guide below the barrel.
  box('barrel crown', [0.037, 0.035, 0.009], [0, 0.016, -0.224], 'black');
  box('bore recess', [0.018, 0.017, 0.002], [0, 0.019, -0.23], 'bore');
  box('guide rod end', [0.011, 0.011, 0.003], [0, -0.001, -0.226], 'steel');
  box('frame dust cover', [0.055, 0.027, 0.175], [0, -0.024, -0.119], 'frame');
  box('frame rear shoulder', [0.064, 0.042, 0.073], [0, -0.025, -0.003], 'frame');
  box('frame top rail left', [0.006, 0.007, 0.145], [-0.027, -0.01, -0.126], 'black');
  box('frame top rail right', [0.006, 0.007, 0.145], [0.027, -0.01, -0.126], 'black');
  box('accessory rail spine', [0.042, 0.009, 0.075], [0, -0.044, -0.154], 'black');
  for (let i = 0; i < 3; i++) {
    box(`accessory rail tooth ${i}`, [0.049, 0.005, 0.007], [0, -0.049, -0.185 + i * 0.026], 'bevel');
  }

  // Polymer backstrap, finger grooves, and coarse raised stipple panels.
  box('grip body', [0.056, 0.121, 0.071], [0, -0.104, 0.016], 'grip', [0.115, 0, 0]);
  box('grip frontstrap', [0.054, 0.103, 0.011], [0, -0.102, -0.022], 'frame', [0.115, 0, 0]);
  box('grip backstrap', [0.057, 0.122, 0.013], [0, -0.102, 0.053], 'black', [0.115, 0, 0]);
  for (const side of [-1, 1]) {
    box(`grip stipple panel ${side}`, [0.003, 0.082, 0.048], [side * 0.029, -0.103, 0.013], 'gripAccent', [0.115, 0, 0]);
    for (let i = 0; i < 4; i++) {
      box(`grip texture row ${side} ${i}`, [0.004, 0.003, 0.047], [side * 0.031, -0.134 + i * 0.018, 0.013], 'black', [0.115, 0, 0]);
    }
    box(`grip badge ${side}`, [0.004, 0.013, 0.023], [side * 0.032, -0.078, 0.014], 'black');
    box(`thumb ledge ${side}`, [0.006, 0.009, 0.052], [side * 0.034, -0.048, 0.015], 'gripAccent');
  }
  box('magazine well flare', [0.062, 0.012, 0.078], [0, -0.162, 0.027], 'frame');
  box('magazine floorplate', [0.064, 0.014, 0.078], [0, -0.171, 0.028], 'black');
  box('floorplate index', [0.016, 0.002, 0.008], [0, -0.18, 0.044], 'gripAccent');
  box('trigger guard front', [0.055, 0.043, 0.007], [0, -0.058, -0.101], 'frame');
  box('trigger guard bottom', [0.056, 0.007, 0.098], [0, -0.077, -0.05], 'frame');
  box('curved trigger', [0.009, 0.031, 0.009], [0.002, -0.047, -0.058], 'steel', [0.25, 0, 0]);
  box('slide stop lever', [0.008, 0.008, 0.048], [0.036, -0.009, -0.028], 'steel');
  box('take-down pin', [0.008, 0.012, 0.012], [0.035, -0.032, -0.06], 'bevel');
  box('magazine release', [0.008, 0.016, 0.019], [-0.035, -0.052, 0.002], 'black');

  // Small three-dot irons keep the P9 functional when aimed in Godot.
  box('front sight base', [0.019, 0.008, 0.017], [0, 0.058, -0.197], 'black');
  box('front sight blade', [0.009, 0.017, 0.009], [0, 0.069, -0.197], 'slideTop');
  box('front sight luminous dot', [0.004, 0.005, 0.002], [0, 0.072, -0.202], 'sight');
  for (const side of [-1, 1]) {
    box(`rear sight wing ${side}`, [0.012, 0.021, 0.015], [side * 0.019, 0.064, -0.005], 'black');
    box(`rear sight dot ${side}`, [0.004, 0.005, 0.002], [side * 0.019, 0.07, -0.013], 'sight');
  }
  box('rear sight bridge', [0.051, 0.006, 0.014], [0, 0.055, -0.005], 'slideTop');

  anchor('Muzzle', [0, 0.019, -0.232]);
  anchor('Eject', [0.03, 0.059, -0.09]);
  anchor('Sight', [0, 0.07, -0.1]);
  anchor('Grip', [0, -0.104, 0.016]);
  anchor('Stock', [0, -0.17, 0.028]);
  anchor('Barrel', [0, 0.019, -0.2]);
  return gun;
}
