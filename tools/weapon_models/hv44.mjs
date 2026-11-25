// HV-44 Judge: heavy six-shot revolver in a chunky late-2000s tactical style.
// Forward is -Z; dimensions follow the original Godot HV-44 viewmodel.
export function buildHv44(THREE) {
  const gun = new THREE.Group();
  gun.name = 'HV-44 Judge';
  const mat = {
    frame: new THREE.MeshStandardMaterial({ color: 0x353e3c, roughness: 0.66, metalness: 0.49 }),
    barrel: new THREE.MeshStandardMaterial({ color: 0x262f30, roughness: 0.62, metalness: 0.56 }),
    facet: new THREE.MeshStandardMaterial({ color: 0x59635e, roughness: 0.59, metalness: 0.46 }),
    cylinder: new THREE.MeshStandardMaterial({ color: 0x46504c, roughness: 0.58, metalness: 0.59 }),
    black: new THREE.MeshStandardMaterial({ color: 0x171d1d, roughness: 0.9, metalness: 0.16 }),
    bore: new THREE.MeshStandardMaterial({ color: 0x080e10, roughness: 0.84 }),
    brass: new THREE.MeshStandardMaterial({ color: 0x8f7851, roughness: 0.61, metalness: 0.57 }),
    grip: new THREE.MeshStandardMaterial({ color: 0x675540, roughness: 0.94, metalness: 0.02 }),
    gripLight: new THREE.MeshStandardMaterial({ color: 0x867255, roughness: 0.93, metalness: 0.02 }),
    sight: new THREE.MeshStandardMaterial({ color: 0xf4aa42, emissive: 0x572405, emissiveIntensity: 0.37, roughness: 0.7 }),
  };
  function box(name, size, pos, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), mat[material]);
    mesh.name = name;
    mesh.position.set(...pos);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    gun.add(mesh);
    return mesh;
  }
  function oct(name, radius, length, pos, material) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, 8), mat[material]);
    mesh.name = name;
    mesh.rotation.x = Math.PI / 2;
    mesh.position.set(...pos);
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

  // Wide upper bridge frames the mechanical heart of the revolver.
  box('upper frame bridge', [0.067, 0.033, 0.174], [0, 0.048, -0.055], 'frame');
  box('bridge top facet', [0.053, 0.009, 0.159], [0, 0.069, -0.057], 'facet');
  box('rear frame block', [0.071, 0.077, 0.066], [0, 0.011, 0.036], 'frame');
  box('front cylinder crane', [0.074, 0.066, 0.021], [0, 0.009, -0.157], 'barrel');
  box('lower frame spine', [0.058, 0.017, 0.111], [0, -0.046, -0.041], 'barrel');
  for (const side of [-1, 1]) {
    box(`frame side cheek ${side}`, [0.009, 0.058, 0.059], [side * 0.035, 0.004, 0.018], 'facet');
    box(`frame side window ${side}`, [0.003, 0.036, 0.087], [side * 0.038, 0.008, -0.077], 'black');
    box(`frame window lower edge ${side}`, [0.006, 0.006, 0.085], [side * 0.04, -0.014, -0.077], 'frame');
  }

  // A faceted oversized cylinder with chamber indicators at the rear and
  // shallow longitudinal flutes on both sides. This is the main silhouette.
  oct('six-shot cylinder', 0.043, 0.082, [0, 0.014, -0.082], 'cylinder');
  oct('cylinder front locking collar', 0.047, 0.009, [0, 0.014, -0.128], 'barrel');
  oct('cylinder rear ratchet', 0.044, 0.008, [0, 0.014, -0.037], 'facet');
  oct('rear cylinder center pin', 0.009, 0.003, [0, 0.014, -0.031], 'black');
  for (let i = 0; i < 6; i++) {
    const a = i * Math.PI / 3;
    const x = Math.sin(a) * 0.027;
    const y = 0.014 + Math.cos(a) * 0.027;
    box(`chamber primer ${i}`, [0.008, 0.008, 0.003], [x, y, -0.031], 'brass');
  }
  for (const side of [-1, 1]) {
    for (let i = 0; i < 3; i++) {
      box(`cylinder side flute ${side} ${i}`, [0.003, 0.009, 0.057], [side * 0.043, -0.01 + i * 0.021, -0.082], 'black');
    }
    box(`cylinder axle button ${side}`, [0.005, 0.019, 0.019], [side * 0.05, 0.014, -0.078], 'facet');
  }
  box('cylinder latch', [0.013, 0.012, 0.034], [0.046, 0.036, 0.015], 'facet');
  box('cylinder latch serration', [0.003, 0.008, 0.025], [0.054, 0.037, 0.015], 'black');
  box('ejector rod', [0.008, 0.008, 0.19], [-0.011, -0.027, -0.278], 'facet');
  box('ejector thumbpiece', [0.018, 0.014, 0.017], [-0.013, -0.023, -0.181], 'black');

  // Heavy octagonal barrel, full underlug, raised vent rib and square muzzle.
  oct('long heavy barrel', 0.028, 0.237, [0, 0.014, -0.28], 'barrel');
  box('top barrel flat', [0.044, 0.009, 0.226], [0, 0.043, -0.281], 'facet');
  box('barrel underlug', [0.045, 0.037, 0.226], [0, -0.024, -0.277], 'frame');
  box('underlug lower line', [0.041, 0.006, 0.201], [0, -0.045, -0.277], 'barrel');
  for (const side of [-1, 1]) {
    box(`barrel side bevel ${side}`, [0.005, 0.028, 0.19], [side * 0.029, 0.01, -0.281], 'facet');
    box(`underlug side inset ${side}`, [0.003, 0.015, 0.159], [side * 0.025, -0.024, -0.278], 'black');
  }
  box('vent rib', [0.044, 0.012, 0.221], [0, 0.054, -0.28], 'barrel');
  for (let i = 0; i < 4; i++) {
    box(`rib vent ${i}`, [0.037, 0.006, 0.022], [0, 0.061, -0.21 - i * 0.044], 'black');
    box(`rib crossbar ${i}`, [0.045, 0.009, 0.008], [0, 0.063, -0.225 - i * 0.044], 'facet');
  }
  box('reinforced muzzle collar', [0.06, 0.07, 0.015], [0, 0.009, -0.403], 'facet');
  box('muzzle dark face', [0.034, 0.034, 0.003], [0, 0.014, -0.413], 'black');
  box('muzzle bore', [0.019, 0.019, 0.002], [0, 0.014, -0.415], 'bore');
  box('underlug front plug', [0.014, 0.014, 0.003], [-0.011, -0.027, -0.397], 'facet');

  // Exposed hammer, contoured wood-tone grip and two-piece grip panels.
  box('hammer spur', [0.04, 0.012, 0.025], [0, 0.054, 0.063], 'barrel', [-0.22, 0, 0]);
  box('hammer thumb pad', [0.044, 0.008, 0.016], [0, 0.063, 0.077], 'facet');
  for (let i = 0; i < 4; i++) {
    box(`hammer notch ${i}`, [0.045, 0.003, 0.002], [0, 0.068, 0.068 + i * 0.004], 'black');
  }
  box('trigger guard front wall', [0.057, 0.047, 0.008], [0, -0.069, -0.054], 'barrel');
  box('trigger guard lower bar', [0.058, 0.008, 0.084], [0, -0.091, -0.014], 'barrel');
  box('trigger', [0.01, 0.035, 0.01], [0, -0.062, -0.016], 'facet', [0.23, 0, 0]);
  box('grip frame tang', [0.05, 0.04, 0.058], [0, -0.037, 0.056], 'barrel');
  box('grip core', [0.053, 0.128, 0.065], [0, -0.114, 0.045], 'grip', [0.12, 0, 0]);
  for (const side of [-1, 1]) {
    box(`grip panel ${side}`, [0.005, 0.099, 0.05], [side * 0.029, -0.112, 0.046], 'gripLight', [0.12, 0, 0]);
    box(`grip screw top ${side}`, [0.003, 0.008, 0.008], [side * 0.033, -0.073, 0.044], 'brass');
    box(`grip screw bottom ${side}`, [0.003, 0.008, 0.008], [side * 0.033, -0.148, 0.051], 'brass');
    for (let i = 0; i < 5; i++) {
      box(`grip checkering ${side} ${i}`, [0.003, 0.003, 0.041], [side * 0.033, -0.089 - i * 0.014, 0.047], 'grip');
    }
  }
  box('grip heel', [0.059, 0.02, 0.069], [0, -0.177, 0.052], 'black');
  box('heel lanyard stud', [0.017, 0.009, 0.018], [0, -0.191, 0.07], 'facet');

  // Square tactical irons with a copper-colored front insert.
  box('front blade foot', [0.029, 0.011, 0.018], [0, 0.07, -0.38], 'barrel');
  box('tall front blade', [0.011, 0.028, 0.011], [0, 0.089, -0.38], 'black');
  box('front blade insert', [0.006, 0.009, 0.003], [0, 0.098, -0.387], 'sight');
  box('rear sight bridge', [0.053, 0.008, 0.022], [0, 0.07, 0.02], 'barrel');
  for (const side of [-1, 1]) {
    box(`rear sight wing ${side}`, [0.012, 0.02, 0.018], [side * 0.021, 0.083, 0.02], 'black');
    box(`rear sight paint ${side}`, [0.004, 0.005, 0.002], [side * 0.021, 0.087, 0.009], 'sight');
  }

  anchor('Muzzle', [0, 0.014, -0.417]);
  anchor('Eject', [0.052, 0.015, -0.082]);
  anchor('Sight', [0, 0.089, -0.18]);
  anchor('Grip', [0, -0.114, 0.045]);
  anchor('Stock', [0, -0.18, 0.052]);
  anchor('Barrel', [0, 0.014, -0.28]);
  return gun;
}
