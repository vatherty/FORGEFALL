// SG-12 Breacher: compact tactical pump shotgun. Local forward is -Z.
// Dimensions follow Arsenal._build_sg12 so existing camera offsets remain useful.
export function buildSg12(THREE) {
  const gun = new THREE.Group();
  gun.name = 'SG-12 Breacher';
  const mat = {
    receiver: new THREE.MeshStandardMaterial({ color: 0x343b39, metalness: 0.65, roughness: 0.54 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x202827, metalness: 0.79, roughness: 0.43 }),
    edge: new THREE.MeshStandardMaterial({ color: 0x59635e, metalness: 0.72, roughness: 0.47 }),
    polymer: new THREE.MeshStandardMaterial({ color: 0x212a27, metalness: 0.08, roughness: 0.83 }),
    olive: new THREE.MeshStandardMaterial({ color: 0x555b43, metalness: 0.08, roughness: 0.82 }),
    tan: new THREE.MeshStandardMaterial({ color: 0xa39270, metalness: 0.12, roughness: 0.78 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x141b1a, metalness: 0, roughness: 0.96 }),
    brass: new THREE.MeshStandardMaterial({ color: 0xb28b4e, metalness: 0.58, roughness: 0.4 }),
    red: new THREE.MeshStandardMaterial({ color: 0x8e3e35, metalness: 0.04, roughness: 0.73 }),
    bore: new THREE.MeshStandardMaterial({ color: 0x080c0c, metalness: 0.22, roughness: 0.95 }),
  };
  function box(name, size, pos, material, parent = gun) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), mat[material]);
    mesh.name = name;
    mesh.position.set(...pos);
    parent.add(mesh);
    return mesh;
  }
  function cylinder(name, radius, length, pos, material, sides = 8, parent = gun) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, sides), mat[material]);
    mesh.name = name;
    mesh.rotation.x = Math.PI / 2;
    mesh.position.set(...pos);
    parent.add(mesh);
    return mesh;
  }
  function anchor(name, pos) {
    const a = new THREE.Object3D();
    a.name = name;
    a.position.set(...pos);
    gun.add(a);
  }

  // Squared alloy receiver, stepped side plates, shell port, pins and controls.
  box('receiver core', [0.086, 0.094, 0.292], [0, 0.002, -0.082], 'receiver');
  box('receiver top spine', [0.074, 0.018, 0.274], [0, 0.054, -0.087], 'steel');
  box('receiver lower trigger housing', [0.070, 0.026, 0.18], [0, -0.054, -0.025], 'steel');
  for (const side of [-1, 1]) {
    box(`machined side panel ${side}`, [0.006, 0.063, 0.225], [side * 0.046, 0.008, -0.099], 'edge');
    box(`panel recess ${side}`, [0.002, 0.045, 0.133], [side * 0.050, 0.007, -0.095], 'receiver');
    for (const z of [-0.186, -0.025]) {
      const pin = cylinder(`receiver pin ${side} ${z}`, 0.006, 0.004, [side * 0.052, -0.017, z], 'steel', 8);
      pin.rotation.z = Math.PI / 2;
    }
  }
  box('right ejection cutout', [0.003, 0.035, 0.087], [0.052, 0.026, -0.102], 'bore');
  box('right ejection bolt', [0.004, 0.016, 0.065], [0.055, 0.024, -0.11], 'edge');
  box('loading gate', [0.042, 0.003, 0.074], [0, -0.070, -0.105], 'bore');
  box('cross bolt safety', [0.104, 0.012, 0.013], [0, -0.037, 0.034], 'steel');
  box('safety red indicator', [0.007, 0.012, 0.015], [0.055, -0.037, 0.034], 'red');

  // Eight-sided barrel with visible dark bore and separate magazine tube.
  cylinder('12 gauge barrel', 0.026, 0.422, [0, 0.014, -0.396], 'steel');
  cylinder('barrel reinforcing sleeve', 0.029, 0.068, [0, 0.014, -0.219], 'receiver');
  cylinder('muzzle crown', 0.030, 0.021, [0, 0.014, -0.610], 'edge');
  cylinder('muzzle black opening', 0.018, 0.003, [0, 0.014, -0.622], 'bore');
  cylinder('underbarrel tube', 0.019, 0.39, [0, -0.042, -0.391], 'receiver');
  cylinder('tube cap', 0.024, 0.019, [0, -0.042, -0.594], 'edge');
  for (const z of [-0.246, -0.546]) {
    box(`barrel tube clamp ${z}`, [0.065, 0.074, 0.018], [0, -0.012, z], 'steel');
    box(`clamp highlight ${z}`, [0.067, 0.006, 0.020], [0, 0.028, z], 'edge');
  }

  // Ribbed sliding pump. Separate group permits pump animation later.
  const pump = new THREE.Group();
  pump.name = 'Pump';
  gun.add(pump);
  box('pump underbody', [0.082, 0.062, 0.174], [0, -0.035, -0.379], 'olive', pump);
  box('pump top bridge', [0.076, 0.018, 0.170], [0, -0.001, -0.379], 'tan', pump);
  for (const side of [-1, 1]) {
    box(`pump rail ${side}`, [0.009, 0.036, 0.150], [side * 0.044, -0.033, -0.379], 'polymer', pump);
    for (let i = 0; i < 7; i++) {
      box(`pump rib ${side} ${i}`, [0.004, 0.043, 0.008], [side * 0.051, -0.034, -0.44 + i * 0.02], 'tan', pump);
    }
  }
  box('pump front ferrule', [0.090, 0.066, 0.013], [0, -0.034, -0.472], 'steel', pump);
  box('pump rear ferrule', [0.090, 0.066, 0.013], [0, -0.034, -0.286], 'steel', pump);

  // Pistol grip, trigger guard and tactical stock; sturdy stepped voxel silhouette.
  const grip = box('angled pistol grip', [0.052, 0.106, 0.058], [0, -0.113, 0.035], 'polymer');
  grip.rotation.x = -0.17;
  for (let i = 0; i < 4; i++) {
    box(`grip checkering ${i}`, [0.054, 0.005, 0.05], [0, -0.082 - i * 0.019, 0.041], 'olive');
  }
  box('trigger guard front', [0.007, 0.034, 0.009], [0, -0.077, -0.028], 'steel');
  box('trigger guard bottom', [0.045, 0.008, 0.080], [0, -0.095, 0.006], 'steel');
  box('trigger', [0.006, 0.026, 0.008], [0, -0.076, 0.004], 'brass');
  box('stock neck', [0.057, 0.056, 0.070], [0, 0.001, 0.098], 'steel');
  box('stock main body', [0.072, 0.085, 0.147], [0, -0.011, 0.185], 'polymer');
  box('stock lower skeleton cut', [0.052, 0.028, 0.070], [0, -0.042, 0.164], 'bore');
  box('stock cheek rest', [0.078, 0.018, 0.142], [0, 0.041, 0.178], 'olive');
  box('buttplate', [0.081, 0.103, 0.018], [0, -0.011, 0.269], 'rubber');
  for (const side of [-1, 1]) {
    box(`buttplate edge ${side}`, [0.008, 0.100, 0.023], [side * 0.041, -0.011, 0.269], 'edge');
    box(`sling loop ${side}`, [0.010, 0.029, 0.017], [side * 0.039, -0.040, 0.113], 'edge');
  }

  // Low snag sighting furniture. White front bead gives an obvious sight line.
  box('rear sight base', [0.054, 0.012, 0.036], [0, 0.063, 0.009], 'steel');
  for (const side of [-1, 1]) {
    box(`rear ghost wing ${side}`, [0.009, 0.034, 0.016], [side * 0.023, 0.082, 0.009], 'edge');
  }
  box('rear ghost bridge', [0.052, 0.008, 0.015], [0, 0.101, 0.009], 'edge');
  box('front sight ramp', [0.043, 0.014, 0.031], [0, 0.049, -0.562], 'steel');
  box('front sight blade', [0.009, 0.025, 0.009], [0, 0.067, -0.562], 'edge');
  box('front white bead', [0.007, 0.007, 0.007], [0, 0.082, -0.562], 'tan');

  // Two spare 12-gauge shells on the left stock, readable from third person.
  box('shell saddle', [0.008, 0.051, 0.065], [-0.045, -0.006, 0.181], 'steel');
  for (const [i, z] of [0.163, 0.193].entries()) {
    box(`shell hull ${i}`, [0.010, 0.039, 0.018], [-0.053, -0.004, z], 'red');
    box(`shell brass ${i}`, [0.012, 0.010, 0.020], [-0.055, -0.027, z], 'brass');
  }

  anchor('Muzzle', [0, 0.014, -0.624]);
  anchor('Eject', [0.056, 0.025, -0.105]);
  anchor('Sight', [0, 0.086, -0.17]);
  anchor('Grip', [0, -0.113, 0.035]);
  anchor('Stock', [0, -0.010, 0.185]);
  anchor('Barrel', [0, 0.014, -0.396]);
  return gun;
}
