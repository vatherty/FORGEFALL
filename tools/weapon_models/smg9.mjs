/** Compact SMG-9. Procedural, GLB-friendly voxel geometry; forward is -Z. */
export function buildSmg9(THREE) {
  const root = new THREE.Group();
  root.name = 'VM_smg9';
  const mat = {
    shell: new THREE.MeshStandardMaterial({ color: 0x3b4040, roughness: 0.77, metalness: 0.35 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x606462, roughness: 0.66, metalness: 0.42 }),
    black: new THREE.MeshStandardMaterial({ color: 0x1c2021, roughness: 0.82, metalness: 0.24 }),
    recess: new THREE.MeshStandardMaterial({ color: 0x101314, roughness: 0.9, metalness: 0.15 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x858983, roughness: 0.54, metalness: 0.68 }),
    tan: new THREE.MeshStandardMaterial({ color: 0x93876e, roughness: 0.9, metalness: 0.08 }),
    tanDark: new THREE.MeshStandardMaterial({ color: 0x716854, roughness: 0.91, metalness: 0.08 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x282b29, roughness: 0.98 }),
    lens: new THREE.MeshStandardMaterial({ color: 0x6d392d, roughness: 0.34, metalness: 0.42, emissive: 0x180500 }),
  };
  let count = 0;
  function box(name, size, xyz, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    root.add(mesh);
    count++;
    return mesh;
  }
  function cyl(name, radius, length, xyz, material, sides = 8, rotation = [Math.PI / 2, 0, 0]) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, sides), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    root.add(mesh);
    count++;
    return mesh;
  }
  function anchor(name, xyz) {
    const node = new THREE.Group();
    node.name = name;
    node.position.set(...xyz);
    root.add(node);
  }

  // Stamped upper, deep lower, and the angular back make the gun read as an SMG.
  box('Upper receiver', [0.084, 0.068, 0.244], [0, 0.021, -0.062], mat.shell);
  box('Receiver crown', [0.078, 0.013, 0.250], [0, 0.061, -0.065], mat.edge);
  box('Receiver lower', [0.075, 0.051, 0.218], [0, -0.037, -0.052], mat.black);
  box('Receiver rear cap', [0.080, 0.102, 0.028], [0, -0.001, 0.071], mat.tanDark);
  box('Receiver forward step', [0.090, 0.081, 0.039], [0, 0.005, -0.191], mat.edge);
  for (const side of [-1, 1]) {
    box(`Receiver side shoulder ${side}`, [0.006, 0.010, 0.230], [side * 0.045, 0.044, -0.062], mat.edge);
    box(`Receiver panel ${side}`, [0.004, 0.037, 0.115], [side * 0.043, 0.001, -0.020], mat.tanDark);
    box(`Receiver panel inset ${side}`, [0.004, 0.026, 0.097], [side * 0.046, 0.001, -0.020], mat.shell);
    box(`Receiver pin front ${side}`, [0.005, 0.012, 0.012], [side * 0.049, -0.035, -0.130], mat.steel);
    box(`Receiver pin rear ${side}`, [0.005, 0.012, 0.012], [side * 0.049, -0.035, 0.035], mat.steel);
  }
  box('Right ejection aperture', [0.004, 0.027, 0.073], [0.044, 0.019, -0.099], mat.recess);
  box('Right bolt glint', [0.005, 0.013, 0.045], [0.047, 0.019, -0.094], mat.steel);
  box('Right ejection lower lip', [0.007, 0.005, 0.079], [0.047, 0.003, -0.099], mat.edge);
  box('Side charging handle stem', [0.020, 0.014, 0.033], [-0.052, 0.029, -0.092], mat.black);
  box('Side charging handle tab', [0.019, 0.021, 0.032], [-0.064, 0.027, -0.073], mat.steel);
  cyl('Fire selector', 0.010, 0.010, [-0.051, -0.011, 0.031], mat.steel, 8, [0, 0, Math.PI / 2]);

  // Compact ventilated handguard and short stepped suppressor.
  box('Handguard main', [0.081, 0.065, 0.161], [0, 0.010, -0.273], mat.tan);
  box('Handguard nose', [0.087, 0.072, 0.021], [0, 0.010, -0.363], mat.tanDark);
  box('Handguard top panel', [0.086, 0.012, 0.169], [0, 0.049, -0.273], mat.tanDark);
  box('Handguard underside', [0.075, 0.010, 0.160], [0, -0.028, -0.273], mat.black);
  for (const side of [-1, 1]) {
    box(`Side accessory rail ${side}`, [0.008, 0.017, 0.125], [side * 0.047, 0.006, -0.274], mat.black);
    for (let i = 0; i < 3; i++) {
      box(`Handguard vent ${side}-${i}`, [0.004, 0.020, 0.024], [side * 0.043, 0.026, -0.324 + i * 0.047], mat.recess);
      box(`Side rail tooth ${side}-${i}`, [0.006, 0.021, 0.010], [side * 0.052, 0.006, -0.319 + i * 0.045], mat.edge);
    }
  }
  cyl('Barrel tube', 0.020, 0.110, [0, 0.006, -0.394], mat.black);
  cyl('Suppressor socket', 0.034, 0.029, [0, 0.006, -0.388], mat.steel);
  cyl('Short suppressor body', 0.029, 0.091, [0, 0.006, -0.450], mat.black, 10);
  cyl('Suppressor front cap', 0.033, 0.012, [0, 0.006, -0.503], mat.edge, 10);
  cyl('Muzzle bore', 0.014, 0.004, [0, 0.006, -0.511], mat.recess, 10);
  for (let i = 0; i < 3; i++) cyl(`Suppressor band ${i}`, 0.031, 0.005, [0, 0.006, -0.421 - i * 0.023], mat.shell, 10);

  // Picatinny run and robust MW2-era red-dot optic.
  box('Top rail spine', [0.054, 0.011, 0.427], [0, 0.071, -0.156], mat.black);
  for (let i = 0; i < 10; i++) box(`Rail tooth ${i}`, [0.068, 0.009, 0.013], [0, 0.080, -0.352 + i * 0.043], mat.edge);
  box('Front backup sight foot', [0.048, 0.015, 0.029], [0, 0.087, -0.343], mat.black);
  box('Front backup sight post', [0.012, 0.033, 0.010], [0, 0.109, -0.343], mat.steel);
  box('Optic clamp', [0.064, 0.014, 0.071], [0, 0.090, -0.069], mat.black);
  box('Optic riser', [0.037, 0.023, 0.040], [0, 0.108, -0.069], mat.edge);
  box('Red dot housing', [0.069, 0.055, 0.060], [0, 0.145, -0.069], mat.black);
  box('Red dot hood', [0.074, 0.012, 0.067], [0, 0.178, -0.069], mat.tanDark);
  for (const side of [-1, 1]) box(`Red dot cheek ${side}`, [0.010, 0.052, 0.067], [side * 0.036, 0.146, -0.069], mat.edge);
  box('Red dot front lens', [0.048, 0.039, 0.003], [0, 0.147, -0.101], mat.lens);
  box('Red dot rear lens', [0.048, 0.039, 0.003], [0, 0.147, -0.037], mat.recess);
  cyl('Red dot brightness dial', 0.014, 0.012, [0.044, 0.153, -0.069], mat.tan, 8, [0, 0, Math.PI / 2]);

  // Straight box magazine, foregrip, pistol grip, and open trigger guard.
  box('Magazine well', [0.071, 0.044, 0.085], [0, -0.076, -0.096], mat.edge);
  box('Straight magazine upper', [0.053, 0.106, 0.063], [0, -0.145, -0.100], mat.black);
  box('Straight magazine lower', [0.050, 0.077, 0.061], [0, -0.236, -0.100], mat.shell);
  box('Magazine base plate', [0.060, 0.016, 0.072], [0, -0.281, -0.100], mat.tanDark);
  for (let i = 0; i < 4; i++) for (const side of [-1, 1]) box(`Magazine stamp ${side}-${i}`, [0.004, 0.006, 0.047], [side * 0.027, -0.146 - i * 0.030, -0.100], mat.edge);
  box('Foregrip clamp', [0.066, 0.016, 0.060], [0, -0.037, -0.279], mat.black);
  box('Foregrip body', [0.044, 0.092, 0.053], [0, -0.089, -0.279], mat.rubber);
  box('Foregrip heel', [0.050, 0.014, 0.059], [0, -0.140, -0.279], mat.tanDark);
  for (let i = 0; i < 3; i++) box(`Foregrip rib ${i}`, [0.047, 0.006, 0.056], [0, -0.066 - i * 0.022, -0.279], mat.tanDark);
  box('Pistol grip top', [0.058, 0.028, 0.065], [0, -0.077, 0.044], mat.black);
  box('Pistol grip', [0.052, 0.115, 0.061], [0, -0.126, 0.062], mat.rubber, [-0.18, 0, 0]);
  box('Pistol grip base', [0.058, 0.014, 0.065], [0, -0.184, 0.072], mat.tanDark, [-0.18, 0, 0]);
  for (const side of [-1, 1]) box(`Grip inset ${side}`, [0.004, 0.065, 0.044], [side * 0.028, -0.126, 0.062], mat.tanDark, [-0.18, 0, 0]);
  box('Trigger guard front', [0.009, 0.042, 0.010], [0, -0.102, -0.012], mat.black);
  box('Trigger guard floor', [0.009, 0.009, 0.057], [0, -0.123, 0.012], mat.black);
  box('Trigger', [0.009, 0.026, 0.009], [0, -0.094, 0.007], mat.steel, [-0.18, 0, 0]);

  // Side-folding wire stock: hinge and two visible bars instead of a solid slab.
  cyl('Folding stock hinge', 0.028, 0.090, [0, -0.002, 0.095], mat.edge, 8, [0, 0, Math.PI / 2]);
  box('Folding stock latch', [0.041, 0.027, 0.035], [-0.045, -0.037, 0.097], mat.black);
  for (const side of [-1, 1]) {
    box(`Stock top bar ${side}`, [0.012, 0.014, 0.160], [side * 0.035, 0.025, 0.187], mat.steel);
    box(`Stock lower bar ${side}`, [0.012, 0.014, 0.162], [side * 0.035, -0.040, 0.187], mat.steel, [-0.11, 0, 0]);
    box(`Stock front diagonal ${side}`, [0.012, 0.070, 0.016], [side * 0.035, -0.009, 0.115], mat.shell, [0.15, 0, 0]);
    box(`Stock rear riser ${side}`, [0.012, 0.088, 0.018], [side * 0.035, -0.011, 0.266], mat.shell);
  }
  box('Stock cheek tab', [0.075, 0.016, 0.115], [0, 0.038, 0.217], mat.tan);
  box('Stock butt frame', [0.078, 0.114, 0.022], [0, -0.013, 0.277], mat.tanDark);
  box('Stock rubber pad', [0.082, 0.118, 0.014], [0, -0.013, 0.291], mat.rubber);
  for (let i = 0; i < 3; i++) box(`Buttpad tread ${i}`, [0.069, 0.006, 0.003], [0, -0.052 + i * 0.037, 0.299], mat.black);

  anchor('Sight', [0, 0.147, -0.069]);
  anchor('Stock', [0, -0.008, 0.281]);
  anchor('Grip', [0, -0.126, 0.062]);
  anchor('Barrel', [0, 0.006, -0.394]);
  anchor('Muzzle', [0, 0.006, -0.514]);
  anchor('Eject', [0.051, 0.020, -0.098]);
  root.userData.meshCount = count;
  root.userData.description = 'SMG-9 voxel tactical submachine gun';
  return root;
}
