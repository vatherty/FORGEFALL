/** Belt-fed tactical LMG. Procedural voxel model; forward is -Z. */
export function buildLmg(THREE) {
  const root = new THREE.Group();
  root.name = 'VM_lmg';
  const m = {
    body: new THREE.MeshStandardMaterial({ color: 0x414541, roughness: 0.78, metalness: 0.38 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x686c67, roughness: 0.66, metalness: 0.48 }),
    dark: new THREE.MeshStandardMaterial({ color: 0x202424, roughness: 0.84, metalness: 0.27 }),
    recess: new THREE.MeshStandardMaterial({ color: 0x121615, roughness: 0.9, metalness: 0.18 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x8a8b7f, roughness: 0.53, metalness: 0.68 }),
    tan: new THREE.MeshStandardMaterial({ color: 0x93876b, roughness: 0.91, metalness: 0.08 }),
    tanDark: new THREE.MeshStandardMaterial({ color: 0x6e6651, roughness: 0.93, metalness: 0.07 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x292c29, roughness: 0.98 }),
    brass: new THREE.MeshStandardMaterial({ color: 0x9c8556, roughness: 0.57, metalness: 0.66 }),
  };
  let count = 0;
  function box(name, size, xyz, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = mesh.receiveShadow = true;
    root.add(mesh); count++;
    return mesh;
  }
  function cyl(name, r, length, xyz, material, sides = 8, rotation = [Math.PI / 2, 0, 0]) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(r, r, length, sides), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    mesh.rotation.set(...rotation);
    mesh.castShadow = mesh.receiveShadow = true;
    root.add(mesh); count++;
    return mesh;
  }
  function anchor(name, xyz) {
    const group = new THREE.Group();
    group.name = name;
    group.position.set(...xyz);
    root.add(group);
  }

  // Wide stamped receiver and raised hinged belt-feed lid.
  box('Heavy receiver shell', [0.106, 0.102, 0.330], [0, 0, -0.105], m.body);
  box('Receiver lower cradle', [0.096, 0.046, 0.290], [0, -0.069, -0.101], m.dark);
  box('Receiver rear wall', [0.111, 0.105, 0.033], [0, 0.002, 0.075], m.tanDark);
  box('Feed cover hinge', [0.122, 0.025, 0.055], [0, 0.076, 0.015], m.edge);
  box('Hinged feed cover', [0.131, 0.025, 0.305], [0, 0.077, -0.116], m.tan);
  box('Feed cover center crown', [0.067, 0.009, 0.270], [0, 0.093, -0.123], m.tanDark);
  box('Feed cover latch', [0.120, 0.024, 0.026], [0, 0.068, -0.270], m.steel);
  for (const side of [-1, 1]) {
    box(`Receiver reinforcement ${side}`, [0.007, 0.079, 0.265], [side * 0.057, -0.003, -0.103], m.edge);
    box(`Receiver access panel ${side}`, [0.005, 0.043, 0.161], [side * 0.061, -0.007, -0.103], m.dark);
    box(`Receiver panel line ${side}`, [0.006, 0.004, 0.150], [side * 0.064, 0.019, -0.103], m.steel);
    box(`Receiver pin front ${side}`, [0.007, 0.015, 0.015], [side * 0.066, -0.038, -0.201], m.steel);
    box(`Receiver pin rear ${side}`, [0.007, 0.015, 0.015], [side * 0.066, -0.038, 0.029], m.steel);
  }
  box('Right ejection recess', [0.005, 0.041, 0.095], [0.063, 0.013, -0.137], m.recess);
  box('Right ejection chute lip', [0.008, 0.007, 0.101], [0.066, -0.011, -0.137], m.steel);
  box('Charging slot', [0.005, 0.015, 0.083], [-0.064, 0.001, -0.105], m.recess);
  box('Charging handle shaft', [0.027, 0.017, 0.026], [-0.075, 0.001, -0.091], m.steel);
  box('Charging handle knob', [0.018, 0.027, 0.025], [-0.092, 0.001, -0.091], m.dark);
  cyl('Fire selector', 0.012, 0.011, [-0.069, -0.025, 0.018], m.steel, 8, [0, 0, Math.PI / 2]);

  // Ammo belt snakes out of the left feed port into the oversized box magazine.
  box('Belt feed mouth', [0.012, 0.045, 0.096], [-0.070, 0.027, -0.136], m.recess);
  for (let i = 0; i < 7; i++) {
    const x = -0.073 - i * 0.011;
    const y = 0.042 - i * 0.011;
    box(`Visible brass cartridge ${i}`, [0.010, 0.012, 0.031], [x, y, -0.137], m.brass);
    box(`Visible belt link ${i}`, [0.004, 0.015, 0.035], [x - 0.005, y + 0.002, -0.137], m.dark);
  }
  box('Ammo box bracket', [0.025, 0.043, 0.090], [-0.080, -0.068, -0.143], m.steel);
  box('Ammo box shell', [0.104, 0.147, 0.194], [-0.107, -0.135, -0.141], m.tan);
  box('Ammo box lid', [0.111, 0.019, 0.201], [-0.107, -0.052, -0.141], m.tanDark);
  box('Ammo box front edge', [0.108, 0.138, 0.013], [-0.107, -0.138, -0.246], m.tanDark);
  box('Ammo box floor edge', [0.110, 0.015, 0.198], [-0.107, -0.216, -0.141], m.dark);
  box('Ammo box side latch', [0.006, 0.032, 0.049], [-0.162, -0.072, -0.154], m.steel);
  for (let i = 0; i < 3; i++) box(`Ammo box stiffener ${i}`, [0.007, 0.114, 0.009], [-0.163, -0.134, -0.205 + i * 0.062], m.tanDark);
  box('Ammo count inset', [0.005, 0.027, 0.056], [-0.165, -0.155, -0.144], m.dark);

  // Long ventilated heat shield over heavy barrel.
  box('Barrel trunnion', [0.119, 0.111, 0.045], [0, 0.002, -0.291], m.edge);
  box('Handguard core', [0.101, 0.090, 0.253], [0, 0.005, -0.431], m.dark);
  box('Heat shield crown', [0.115, 0.014, 0.260], [0, 0.057, -0.433], m.tan);
  box('Handguard lower rail', [0.087, 0.011, 0.251], [0, -0.047, -0.431], m.tanDark);
  box('Handguard nose collar', [0.119, 0.097, 0.022], [0, 0.004, -0.566], m.steel);
  for (const side of [-1, 1]) {
    box(`Heat shield side ${side}`, [0.012, 0.076, 0.246], [side * 0.054, 0.004, -0.431], m.tan);
    for (let i = 0; i < 4; i++) {
      box(`Heat vent ${side}-${i}`, [0.005, 0.028, 0.037], [side * 0.062, 0.014, -0.526 + i * 0.055], m.recess);
      box(`Heat vent rim ${side}-${i}`, [0.005, 0.004, 0.042], [side * 0.064, 0.032, -0.526 + i * 0.055], m.steel);
    }
  }
  cyl('Exposed heavy barrel', 0.025, 0.143, [0, 0.004, -0.629], m.dark, 10);
  cyl('Barrel cooling collar', 0.035, 0.033, [0, 0.004, -0.605], m.steel, 10);
  cyl('Muzzle brake body', 0.034, 0.073, [0, 0.004, -0.713], m.edge, 10);
  cyl('Muzzle bore', 0.017, 0.004, [0, 0.004, -0.751], m.recess, 10);
  for (const side of [-1, 1]) box(`Muzzle brake port ${side}`, [0.005, 0.017, 0.020], [side * 0.034, 0.004, -0.718], m.recess);

  // Carry handle arches over the belt-feed cover; rail and irons remain usable.
  box('Carry handle pivot front', [0.017, 0.040, 0.026], [-0.044, 0.114, -0.210], m.steel);
  box('Carry handle pivot rear', [0.017, 0.040, 0.026], [-0.044, 0.114, -0.015], m.steel);
  box('Carry handle forward rise', [0.017, 0.061, 0.018], [-0.044, 0.154, -0.210], m.dark, [0.18, 0, 0]);
  box('Carry handle rear rise', [0.017, 0.061, 0.018], [-0.044, 0.154, -0.015], m.dark, [-0.18, 0, 0]);
  box('Carry handle grip', [0.029, 0.020, 0.200], [-0.044, 0.184, -0.112], m.rubber);
  for (let i = 0; i < 4; i++) box(`Carry handle rib ${i}`, [0.031, 0.005, 0.008], [-0.044, 0.195, -0.174 + i * 0.040], m.tanDark);
  box('Top rail', [0.044, 0.012, 0.420], [0.024, 0.097, -0.223], m.dark);
  for (let i = 0; i < 10; i++) box(`Top rail tooth ${i}`, [0.054, 0.008, 0.014], [0.024, 0.106, -0.403 + i * 0.038], m.edge);
  box('Rear sight base', [0.052, 0.023, 0.044], [0.024, 0.116, 0.007], m.dark);
  for (const side of [-1, 1]) box(`Rear sight wing ${side}`, [0.011, 0.039, 0.018], [0.024 + side * 0.020, 0.145, 0.007], m.dark);
  box('Front sight block', [0.059, 0.019, 0.028], [0, 0.079, -0.562], m.dark);
  box('Front sight post', [0.012, 0.054, 0.012], [0, 0.114, -0.562], m.steel);
  for (const side of [-1, 1]) box(`Front sight ear ${side}`, [0.011, 0.037, 0.014], [side * 0.023, 0.105, -0.562], m.dark);

  // Deployable bipod tucked beneath the forward handguard.
  box('Bipod clamp', [0.083, 0.026, 0.048], [0, -0.053, -0.537], m.steel);
  for (const side of [-1, 1]) {
    cyl(`Bipod hinge ${side}`, 0.015, 0.018, [side * 0.048, -0.060, -0.537], m.dark, 8, [0, 0, Math.PI / 2]);
    box(`Bipod folded leg ${side}`, [0.013, 0.014, 0.160], [side * 0.057, -0.083, -0.445], m.steel, [0, side * 0.03, 0]);
    box(`Bipod foot ${side}`, [0.027, 0.017, 0.025], [side * 0.057, -0.083, -0.353], m.rubber);
  }

  // Fixed shoulder stock and ergonomic controls.
  box('Stock neck', [0.092, 0.092, 0.070], [0, -0.001, 0.096], m.dark);
  box('Fixed stock core', [0.093, 0.112, 0.198], [0, 0.010, 0.221], m.tan);
  box('Stock cheek weld', [0.096, 0.021, 0.183], [0, 0.070, 0.223], m.tanDark);
  box('Stock lower taper', [0.074, 0.043, 0.175], [0, -0.057, 0.211], m.tanDark);
  for (const side of [-1, 1]) {
    box(`Stock recessed panel ${side}`, [0.005, 0.054, 0.119], [side * 0.049, 0.008, 0.232], m.dark);
    box(`Stock sling eye ${side}`, [0.009, 0.025, 0.024], [side * 0.050, -0.019, 0.315], m.steel);
  }
  box('Buttpad frame', [0.101, 0.135, 0.025], [0, 0.004, 0.331], m.tanDark);
  box('Rubber buttpad', [0.106, 0.141, 0.016], [0, 0.004, 0.353], m.rubber);
  for (let i = 0; i < 4; i++) box(`Buttpad rib ${i}`, [0.093, 0.006, 0.003], [0, -0.049 + i * 0.034, 0.363], m.dark);
  box('Pistol grip collar', [0.062, 0.031, 0.069], [0, -0.086, 0.032], m.dark);
  box('Pistol grip', [0.056, 0.132, 0.069], [0, -0.150, 0.050], m.rubber, [-0.16, 0, 0]);
  box('Pistol grip foot', [0.065, 0.016, 0.073], [0, -0.220, 0.061], m.tanDark);
  for (const side of [-1, 1]) box(`Pistol grip checkering ${side}`, [0.004, 0.077, 0.046], [side * 0.030, -0.156, 0.050], m.tanDark, [-0.16, 0, 0]);
  box('Trigger guard front', [0.009, 0.049, 0.011], [0, -0.112, -0.026], m.dark);
  box('Trigger guard bottom', [0.009, 0.010, 0.071], [0, -0.134, 0.002], m.dark);
  box('Trigger blade', [0.009, 0.027, 0.009], [0, -0.104, -0.002], m.steel, [-0.16, 0, 0]);

  anchor('Sight', [0.024, 0.143, 0.007]);
  anchor('Stock', [0, 0.004, 0.345]);
  anchor('Grip', [0, -0.150, 0.050]);
  anchor('Barrel', [0, 0.004, -0.629]);
  anchor('Muzzle', [0, 0.004, -0.754]);
  anchor('Eject', [0.071, 0.013, -0.137]);
  root.userData.meshCount = count;
  root.userData.description = 'Heavy belt-fed tactical light machine gun';
  return root;
}
