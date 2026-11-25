// LR-8 Longeye: a late-2000s tactical bolt-action rifle in FORGEFALL's
// deliberately chunky voxel language. Forward is -Z; all dimensions are
// matched to the original Godot first-person viewmodel.
export function buildLr8(THREE) {
  const gun = new THREE.Group();
  gun.name = 'LR-8 Longeye';

  const mat = {
    receiver: new THREE.MeshStandardMaterial({ color: 0x313a38, roughness: 0.74, metalness: 0.34 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x202928, roughness: 0.66, metalness: 0.48 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x4b5552, roughness: 0.52, metalness: 0.62 }),
    highlight: new THREE.MeshStandardMaterial({ color: 0x68716c, roughness: 0.59, metalness: 0.43 }),
    polymer: new THREE.MeshStandardMaterial({ color: 0x817858, roughness: 0.92, metalness: 0.03 }),
    polymerDark: new THREE.MeshStandardMaterial({ color: 0x555340, roughness: 0.96, metalness: 0.01 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x171b1b, roughness: 1 }),
    marking: new THREE.MeshStandardMaterial({ color: 0xaaa588, roughness: 0.9 }),
    lens: new THREE.MeshStandardMaterial({ color: 0x244b56, roughness: 0.2, metalness: 0.2, emissive: 0x10252c, emissiveIntensity: 0.27 }),
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

  // Squared action and long, faceted barrel; broad shoulders read clearly in FPS.
  box('receiver core', [0.078, 0.082, 0.284], [0, 0.005, -0.045], 'receiver');
  box('left action plate', [0.008, 0.063, 0.236], [-0.043, 0.003, -0.045], 'steel');
  box('right action plate', [0.008, 0.063, 0.236], [0.043, 0.003, -0.045], 'edge');
  box('front action collar', [0.093, 0.083, 0.036], [0, 0.006, -0.185], 'edge');
  box('angled rear action shoulder', [0.082, 0.069, 0.065], [0, 0.001, 0.105], 'polymerDark');
  box('ejection port darkwell', [0.003, 0.029, 0.082], [0.048, 0.026, -0.014], 'rubber');
  box('ejection port rim top', [0.006, 0.005, 0.088], [0.052, 0.043, -0.014], 'highlight');
  box('ejection port rim bottom', [0.006, 0.005, 0.088], [0.052, 0.008, -0.014], 'steel');
  box('bolt body', [0.017, 0.019, 0.16], [0.018, 0.026, 0.001], 'steel');
  box('bolt handle stem', [0.073, 0.013, 0.013], [0.064, 0.014, 0.05], 'steel');
  box('bolt handle downward tip', [0.019, 0.03, 0.019], [0.103, -0.004, 0.05], 'edge');
  box('bolt knob', [0.026, 0.023, 0.026], [0.103, -0.026, 0.05], 'rubber');
  box('trigger guard', [0.055, 0.008, 0.09], [0, -0.062, 0.035], 'edge');
  box('trigger', [0.009, 0.03, 0.008], [0.005, -0.061, 0.007], 'steel', [0.24, 0, 0]);
  box('safety selector', [0.014, 0.013, 0.026], [-0.05, 0.04, 0.059], 'highlight');

  oct('long free-float barrel', 0.016, 0.475, [0, 0.007, -0.418], 'edge');
  oct('exposed barrel silver line', 0.012, 0.275, [0, 0.007, -0.523], 'steel');
  for (const [i, z] of [-0.309, -0.39, -0.47, -0.565].entries()) {
    oct(`barrel contour ring ${i + 1}`, 0.018, 0.012, [0, 0.007, z], i % 2 ? 'edge' : 'steel');
  }
  oct('muzzle brake', 0.027, 0.078, [0, 0.007, -0.673], 'edge');
  box('muzzle brake top flat', [0.047, 0.007, 0.064], [0, 0.033, -0.673], 'steel');
  for (const s of [-1, 1]) {
    box(`muzzle port ${s}`, [0.002, 0.011, 0.015], [s * 0.026, 0.01, -0.679], 'rubber');
  }
  box('muzzle dark opening', [0.024, 0.023, 0.003], [0, 0.007, -0.713], 'rubber');

  // Tan modular chassis, barrel shroud, cheekpiece, and a stock that frames
  // the familiar modern sniper silhouette without thin fragile detail.
  box('long fore-end', [0.091, 0.055, 0.24], [0, -0.037, -0.283], 'polymer');
  box('fore-end upper spine', [0.074, 0.019, 0.235], [0, -0.005, -0.283], 'polymerDark');
  box('fore-end lower chamfer', [0.068, 0.014, 0.224], [0, -0.069, -0.281], 'polymerDark');
  for (const s of [-1, 1]) {
    box(`handguard side rail ${s}`, [0.008, 0.012, 0.18], [s * 0.05, -0.017, -0.28], 'edge');
    for (let i = 0; i < 5; i++) {
      box(`vent slot ${s} ${i}`, [0.003, 0.011, 0.018], [s * 0.047, -0.043, -0.2 - i * 0.04], 'polymerDark');
    }
  }
  box('bipod yoke', [0.065, 0.018, 0.03], [0, -0.076, -0.341], 'edge');
  for (const s of [-1, 1]) {
    box(`folded bipod leg ${s}`, [0.01, 0.013, 0.16], [s * 0.035, -0.084, -0.35], 'steel');
    box(`bipod foot ${s}`, [0.018, 0.014, 0.015], [s * 0.035, -0.087, -0.43], 'rubber');
  }
  box('chassis rear', [0.076, 0.07, 0.16], [0, -0.021, 0.126], 'polymer');
  box('stock narrow connector', [0.043, 0.047, 0.09], [0, -0.012, 0.216], 'edge');
  box('stock rear body', [0.075, 0.078, 0.105], [0, -0.021, 0.264], 'polymerDark');
  box('stock heel', [0.069, 0.032, 0.065], [0, -0.071, 0.27], 'polymer');
  box('adjustable cheek riser', [0.07, 0.017, 0.145], [0, 0.055, 0.199], 'polymer');
  box('cheek riser pad', [0.064, 0.008, 0.11], [0, 0.069, 0.196], 'rubber');
  for (const s of [-1, 1]) {
    box(`stock cheek spacer ${s}`, [0.008, 0.027, 0.016], [s * 0.031, 0.031, 0.163], 'steel');
    box(`stock frame window ${s}`, [0.003, 0.027, 0.041], [s * 0.039, -0.032, 0.262], 'rubber');
    box(`stock strap loop ${s}`, [0.009, 0.027, 0.019], [s * 0.041, -0.044, 0.181], 'steel');
  }
  box('buttpad backing', [0.083, 0.104, 0.013], [0, -0.02, 0.324], 'steel');
  box('ribbed rubber buttpad', [0.088, 0.11, 0.025], [0, -0.02, 0.343], 'rubber');
  for (let i = 0; i < 4; i++) {
    box(`buttpad rib ${i}`, [0.089, 0.004, 0.006], [0, -0.057 + i * 0.023, 0.359], 'polymerDark');
  }
  box('pistol grip', [0.055, 0.116, 0.052], [0, -0.093, 0.091], 'polymerDark', [0.17, 0, 0]);
  box('pistol grip backstrap', [0.055, 0.096, 0.009], [0, -0.096, 0.123], 'rubber', [0.17, 0, 0]);
  for (let i = 0; i < 3; i++) {
    box(`grip stipple band ${i}`, [0.055, 0.005, 0.044], [0, -0.111 - i * 0.021, 0.091], 'polymer');
  }
  box('magazine well', [0.059, 0.039, 0.086], [0, -0.048, -0.062], 'edge');
  box('box magazine', [0.052, 0.108, 0.066], [0, -0.119, -0.064], 'polymerDark', [0.07, 0, 0]);
  box('magazine floorplate', [0.06, 0.013, 0.075], [0, -0.18, -0.058], 'edge');
  for (const s of [-1, 1]) {
    box(`magazine grip rib ${s}`, [0.003, 0.006, 0.055], [s * 0.027, -0.108, -0.066], 'polymer');
    box(`magazine index mark ${s}`, [0.003, 0.012, 0.01], [s * 0.028, -0.153, -0.06], 'marking');
  }

  // Eight-sided optic, raised on two squared rings, with visible dark glass.
  box('scope picatinny rail', [0.057, 0.012, 0.225], [0, 0.055, -0.059], 'edge');
  for (let i = 0; i < 7; i++) {
    box(`scope rail tooth ${i}`, [0.059, 0.006, 0.009], [0, 0.064, 0.027 - i * 0.028], 'steel');
  }
  for (const [i, z] of [-0.125, 0.009].entries()) {
    box(`scope mount post ${i}`, [0.032, 0.036, 0.034], [0, 0.079, z], 'edge');
    box(`scope mount band ${i}`, [0.071, 0.012, 0.035], [0, 0.101, z], 'steel');
  }
  oct('scope main tube', 0.029, 0.213, [0, 0.111, -0.063], 'edge');
  oct('scope objective bell', 0.041, 0.066, [0, 0.111, -0.207], 'receiver');
  oct('scope objective rim', 0.043, 0.012, [0, 0.111, -0.245], 'steel');
  box('scope objective lens', [0.052, 0.052, 0.002], [0, 0.111, -0.252], 'lens');
  oct('scope ocular bell', 0.037, 0.06, [0, 0.111, 0.076], 'receiver');
  oct('scope ocular rubber ring', 0.039, 0.017, [0, 0.111, 0.112], 'rubber');
  box('scope rear glass', [0.044, 0.044, 0.002], [0, 0.111, 0.122], 'lens');
  box('elevation turret base', [0.028, 0.014, 0.028], [0, 0.149, -0.047], 'steel');
  box('elevation turret dial', [0.035, 0.021, 0.035], [0, 0.166, -0.047], 'edge');
  box('elevation index', [0.003, 0.002, 0.014], [0, 0.178, -0.047], 'marking');
  box('windage turret', [0.018, 0.031, 0.031], [0.038, 0.111, -0.047], 'edge');
  box('windage index', [0.002, 0.006, 0.015], [0.049, 0.111, -0.047], 'marking');

  anchor('Muzzle', [0, 0.007, -0.716]);
  anchor('Eject', [0.055, 0.026, -0.014]);
  anchor('Sight', [0, 0.111, -0.063]);
  anchor('Grip', [0, -0.093, 0.091]);
  anchor('Stock', [0, -0.02, 0.28]);
  anchor('Barrel', [0, 0.007, -0.418]);
  return gun;
}
