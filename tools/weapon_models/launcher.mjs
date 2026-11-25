/** Heavy modular launcher. Procedural voxel geometry; forward is -Z. */
export function buildLauncher(THREE) {
  const root = new THREE.Group();
  root.name = 'VM_launcher';
  const mat = {
    shell: new THREE.MeshStandardMaterial({ color: 0x414541, roughness: 0.79, metalness: 0.32 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x696d65, roughness: 0.68, metalness: 0.44 }),
    black: new THREE.MeshStandardMaterial({ color: 0x1d2221, roughness: 0.85, metalness: 0.23 }),
    recess: new THREE.MeshStandardMaterial({ color: 0x0d1111, roughness: 0.96, metalness: 0.12 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x898b82, roughness: 0.53, metalness: 0.67 }),
    tan: new THREE.MeshStandardMaterial({ color: 0x94866c, roughness: 0.91, metalness: 0.08 }),
    tanDark: new THREE.MeshStandardMaterial({ color: 0x6f6650, roughness: 0.93, metalness: 0.07 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x292c2a, roughness: 0.99 }),
    amber: new THREE.MeshStandardMaterial({ color: 0xb8793b, roughness: 0.49, metalness: 0.42, emissive: 0x1a0801 }),
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
  function cyl(name, radius, length, xyz, material, sides = 10, rotation = [Math.PI / 2, 0, 0]) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, sides), material);
    mesh.name = name;
    mesh.position.set(...xyz);
    mesh.rotation.set(...rotation);
    mesh.castShadow = mesh.receiveShadow = true;
    root.add(mesh); count++;
    return mesh;
  }
  function anchor(name, xyz) {
    const node = new THREE.Group();
    node.name = name;
    node.position.set(...xyz);
    root.add(node);
  }

  // Oversized octagonal launch tube with a deep dark bore and reinforcing rings.
  cyl('Launch tube main', 0.071, 0.432, [0, 0.026, -0.377], mat.shell, 10);
  cyl('Tube rear collar', 0.078, 0.042, [0, 0.026, -0.169], mat.edge, 10);
  cyl('Tube front sleeve', 0.080, 0.071, [0, 0.026, -0.603], mat.tan, 10);
  cyl('Muzzle rim', 0.090, 0.033, [0, 0.026, -0.655], mat.edge, 10);
  cyl('Muzzle black bore', 0.063, 0.004, [0, 0.026, -0.673], mat.recess, 10);
  cyl('Muzzle inner throat', 0.047, 0.003, [0, 0.026, -0.676], mat.black, 10);
  for (let i = 0; i < 3; i++) cyl(`Tube reinforcement band ${i}`, 0.076, 0.015, [0, 0.026, -0.237 - i * 0.142], mat.tanDark, 10);
  box('Tube top spine', [0.058, 0.013, 0.429], [0, 0.100, -0.383], mat.tanDark);
  box('Tube bottom spine', [0.055, 0.013, 0.420], [0, -0.048, -0.382], mat.black);
  for (const side of [-1, 1]) {
    box(`Tube side rib ${side}`, [0.013, 0.022, 0.355], [side * 0.072, 0.025, -0.384], mat.edge);
    for (let i = 0; i < 4; i++) box(`Tube side vent ${side}-${i}`, [0.005, 0.019, 0.040], [side * 0.080, 0.026, -0.516 + i * 0.084], mat.recess);
  }

  // Wide, squared breech visually supports a heavy and swappable payload canister.
  box('Breech upper shell', [0.155, 0.116, 0.254], [0, 0.012, -0.069], mat.shell);
  box('Breech top lid', [0.168, 0.020, 0.260], [0, 0.078, -0.071], mat.tan);
  box('Breech front lock', [0.169, 0.111, 0.025], [0, 0.011, -0.210], mat.edge);
  box('Breech lower frame', [0.144, 0.042, 0.219], [0, -0.070, -0.063], mat.black);
  box('Breech rear lock', [0.158, 0.120, 0.034], [0, 0.006, 0.068], mat.tanDark);
  for (const side of [-1, 1]) {
    box(`Breech side inset ${side}`, [0.006, 0.072, 0.164], [side * 0.082, 0.010, -0.055], mat.tanDark);
    box(`Breech side raised frame ${side}`, [0.008, 0.008, 0.177], [side * 0.087, 0.051, -0.055], mat.steel);
    box(`Breech hinge pin ${side}`, [0.010, 0.020, 0.020], [side * 0.089, 0.018, -0.173], mat.steel);
    box(`Breech latch ${side}`, [0.011, 0.029, 0.039], [side * 0.090, 0.024, 0.036], mat.black);
  }
  box('Right ejection hatch', [0.006, 0.065, 0.113], [0.089, -0.006, -0.085], mat.recess);
  box('Right ejecting port lip', [0.010, 0.008, 0.124], [0.091, -0.043, -0.085], mat.edge);
  box('Right hatch handle', [0.016, 0.018, 0.040], [0.102, 0.003, -0.026], mat.steel);
  cyl('Left safety selector', 0.012, 0.015, [-0.097, -0.032, 0.016], mat.steel, 8, [0, 0, Math.PI / 2]);

  // Large drum canister beneath the breech; its two broad end caps read clearly.
  box('Canister neck', [0.103, 0.039, 0.113], [0, -0.092, -0.084], mat.edge);
  cyl('Payload drum body', 0.103, 0.149, [0, -0.173, -0.081], mat.tan, 12, [0, 0, Math.PI / 2]);
  cyl('Payload drum left cap', 0.106, 0.015, [-0.084, -0.173, -0.081], mat.tanDark, 12, [0, 0, Math.PI / 2]);
  cyl('Payload drum right cap', 0.106, 0.015, [0.084, -0.173, -0.081], mat.tanDark, 12, [0, 0, Math.PI / 2]);
  cyl('Payload drum left hub', 0.037, 0.018, [-0.096, -0.173, -0.081], mat.steel, 10, [0, 0, Math.PI / 2]);
  cyl('Payload drum right hub', 0.037, 0.018, [0.096, -0.173, -0.081], mat.steel, 10, [0, 0, Math.PI / 2]);
  cyl('Payload drum core recess', 0.015, 0.021, [0.110, -0.173, -0.081], mat.recess, 10, [0, 0, Math.PI / 2]);
  for (let i = 0; i < 6; i++) {
    const angle = (i * Math.PI) / 3;
    const y = -0.173 + 0.067 * Math.cos(angle);
    const z = -0.081 + 0.067 * Math.sin(angle);
    cyl(`Payload drum chamber ${i}`, 0.017, 0.004, [0.096, y, z], mat.black, 8, [0, 0, Math.PI / 2]);
    cyl(`Payload drum chamber rim ${i}`, 0.008, 0.006, [0.100, y, z], mat.amber, 8, [0, 0, Math.PI / 2]);
  }
  box('Drum release paddle', [0.022, 0.045, 0.055], [-0.100, -0.109, -0.120], mat.black);
  box('Drum release highlight', [0.006, 0.018, 0.035], [-0.113, -0.104, -0.120], mat.steel);

  // Tactical top rail, optic, and ladder-style ranging sight.
  box('Top rail spine', [0.055, 0.015, 0.395], [0, 0.102, -0.089], mat.black);
  for (let i = 0; i < 9; i++) box(`Top rail tooth ${i}`, [0.070, 0.008, 0.014], [0, 0.114, -0.254 + i * 0.043], mat.edge);
  box('Optic clamp', [0.072, 0.017, 0.080], [0, 0.124, 0.001], mat.black);
  box('Optic riser', [0.045, 0.032, 0.042], [0, 0.149, 0.001], mat.edge);
  box('Launcher optic housing', [0.088, 0.066, 0.073], [0, 0.196, 0.001], mat.black);
  box('Optic upper hood', [0.092, 0.014, 0.077], [0, 0.235, 0.001], mat.tanDark);
  box('Optic front lens', [0.061, 0.048, 0.004], [0, 0.198, -0.038], mat.amber);
  box('Optic rear glass', [0.061, 0.048, 0.004], [0, 0.198, 0.041], mat.recess);
  for (const side of [-1, 1]) box(`Optic shell cheek ${side}`, [0.011, 0.067, 0.071], [side * 0.046, 0.198, 0.001], mat.edge);
  box('Ranging ladder base', [0.063, 0.014, 0.027], [0, 0.126, -0.260], mat.black);
  for (const side of [-1, 1]) box(`Ranging ladder side ${side}`, [0.011, 0.070, 0.012], [side * 0.026, 0.165, -0.260], mat.steel);
  for (let i = 0; i < 3; i++) box(`Ranging ladder rung ${i}`, [0.061, 0.007, 0.009], [0, 0.150 + i * 0.022, -0.260], mColor(i));

  // Front hand support, pistol grip, and open trigger guard.
  box('Handguard front clamp', [0.088, 0.016, 0.077], [0, -0.054, -0.479], mat.black);
  box('Vertical hand support', [0.059, 0.122, 0.076], [0, -0.121, -0.479], mat.rubber);
  box('Hand support base', [0.070, 0.017, 0.083], [0, -0.192, -0.479], mat.tanDark);
  for (let i = 0; i < 4; i++) box(`Hand support rib ${i}`, [0.062, 0.007, 0.080], [0, -0.083 - i * 0.028, -0.479], mat.tanDark);
  box('Grip collar', [0.068, 0.029, 0.078], [0, -0.087, 0.071], mat.black);
  box('Pistol grip', [0.061, 0.132, 0.071], [0, -0.153, 0.085], mat.rubber, [-0.17, 0, 0]);
  box('Pistol grip foot', [0.069, 0.017, 0.080], [0, -0.222, 0.099], mat.tanDark);
  for (const side of [-1, 1]) box(`Grip texture ${side}`, [0.005, 0.072, 0.047], [side * 0.032, -0.151, 0.086], mat.tanDark, [-0.17, 0, 0]);
  box('Trigger guard forward post', [0.010, 0.057, 0.011], [0, -0.102, 0.009], mat.black);
  box('Trigger guard bottom bar', [0.010, 0.010, 0.068], [0, -0.131, 0.040], mat.black);
  box('Trigger blade', [0.010, 0.028, 0.009], [0, -0.104, 0.044], mat.steel, [-0.18, 0, 0]);

  // Broad buttstock gives the heavy launcher a braced shoulder silhouette.
  box('Stock root', [0.103, 0.102, 0.075], [0, -0.001, 0.108], mat.edge);
  box('Stock main', [0.107, 0.127, 0.203], [0, 0.001, 0.236], mat.tan);
  box('Stock cheek piece', [0.110, 0.027, 0.180], [0, 0.080, 0.239], mat.tanDark);
  box('Stock lower brace', [0.088, 0.046, 0.163], [0, -0.069, 0.230], mat.dark);
  for (const side of [-1, 1]) {
    box(`Stock side inset ${side}`, [0.005, 0.058, 0.126], [side * 0.056, -0.004, 0.242], mat.tanDark);
    box(`Stock side slot ${side}`, [0.006, 0.020, 0.064], [side * 0.059, 0.001, 0.260], mat.black);
    box(`Stock sling point ${side}`, [0.009, 0.024, 0.027], [side * 0.060, -0.041, 0.312], mat.steel);
  }
  box('Buttpad frame', [0.117, 0.143, 0.027], [0, 0.002, 0.352], mat.tanDark);
  box('Buttpad rubber', [0.123, 0.149, 0.018], [0, 0.002, 0.370], mat.rubber);
  for (let i = 0; i < 4; i++) box(`Buttpad tread ${i}`, [0.111, 0.006, 0.003], [0, -0.052 + i * 0.036, 0.381], mat.black);

  function mColor(i) { return i === 1 ? mat.amber : mat.steel; }
  anchor('Sight', [0, 0.198, 0.001]);
  anchor('Stock', [0, 0.002, 0.363]);
  anchor('Grip', [0, -0.153, 0.085]);
  anchor('Barrel', [0, 0.026, -0.377]);
  anchor('Muzzle', [0, 0.026, -0.681]);
  anchor('Eject', [0.104, -0.005, -0.085]);
  root.userData.meshCount = count;
  root.userData.description = 'Modular heavy voxel launcher';
  return root;
}
