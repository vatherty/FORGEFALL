/**
 * AR-7 tactical carbine. Forward is -Z; coordinates match arsenal.gd's viewmodel.
 * All geometry is procedural and GLB friendly. The empty named groups are sockets.
 */
export function buildAr7(THREE) {
  const root = new THREE.Group();
  root.name = 'VM_ar7';

  const mat = {
    receiver: new THREE.MeshStandardMaterial({ color: 0x34383a, roughness: 0.78, metalness: 0.32 }),
    receiverEdge: new THREE.MeshStandardMaterial({ color: 0x555b5c, roughness: 0.7, metalness: 0.4 }),
    black: new THREE.MeshStandardMaterial({ color: 0x1b1e20, roughness: 0.82, metalness: 0.25 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x777c79, roughness: 0.48, metalness: 0.76 }),
    tan: new THREE.MeshStandardMaterial({ color: 0x97896b, roughness: 0.92, metalness: 0.08 }),
    tanShadow: new THREE.MeshStandardMaterial({ color: 0x6f644e, roughness: 0.94, metalness: 0.06 }),
    tanLight: new THREE.MeshStandardMaterial({ color: 0xb1a180, roughness: 0.89, metalness: 0.07 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x252524, roughness: 0.98 }),
    port: new THREE.MeshStandardMaterial({ color: 0x111316, roughness: 0.66, metalness: 0.43 }),
    lens: new THREE.MeshStandardMaterial({ color: 0x713d27, roughness: 0.3, metalness: 0.62, emissive: 0x1b0802 }),
  };

  let count = 0;
  function box(name, size, pos, material, rotation) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
    mesh.name = name;
    mesh.position.set(...pos);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    root.add(mesh);
    count++;
    return mesh;
  }
  function cyl(name, r, depth, pos, material, sides = 8, rotation = [Math.PI / 2, 0, 0]) {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(r, r, depth, sides), material);
    mesh.name = name;
    mesh.position.set(...pos);
    mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    root.add(mesh);
    count++;
    return mesh;
  }
  // Flat-sided polygon prism, useful for a recognizable receiver profile.
  function profile(name, points, width, material, x = 0) {
    const shape = new THREE.Shape();
    shape.moveTo(points[0][0], points[0][1]);
    for (let i = 1; i < points.length; i++) shape.lineTo(points[i][0], points[i][1]);
    shape.closePath();
    // Shape XY -> world ZY. Positive shape X projects toward the buttstock.
    const geo = new THREE.ExtrudeGeometry(shape, { depth: width, bevelEnabled: false });
    geo.rotateY(-Math.PI / 2);
    geo.translate(x + width / 2, 0, 0);
    const mesh = new THREE.Mesh(geo, material);
    mesh.name = name;
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

  // Upper/lower receiver, with stepped forged shape rather than one plain cuboid.
  profile('Forged upper receiver', [[-0.26,-0.025],[-0.24,0.044],[-0.16,0.057],[0.022,0.057],[0.052,0.025],[0.052,-0.034],[-0.03,-0.05],[-0.17,-0.046]], 0.075, mat.receiver);
  profile('Lower receiver', [[-0.21,-0.042],[-0.10,-0.048],[-0.055,-0.082],[0.032,-0.072],[0.041,-0.026],[-0.02,-0.02],[-0.175,-0.026]], 0.068, mat.receiverEdge);
  box('Upper beveled edge', [0.077,0.009,0.258], [0,0.051,-0.103], mat.receiverEdge);
  box('Buffer socket', [0.061,0.066,0.049], [0,-0.003,0.064], mat.black);
  box('Forward delta ring', [0.082,0.082,0.028], [0,0.004,-0.265], mat.steel);
  box('Dust cover inset right', [0.003,0.033,0.105], [0.04,-0.003,-0.09], mat.port);
  box('Dust cover frame lower', [0.006,0.006,0.112], [0.044,-0.023,-0.09], mat.steel);
  box('Ejection glint', [0.002,0.017,0.050], [0.043,0.002,-0.092], mat.steel);
  box('Bolt release', [0.005,0.019,0.029], [-0.041,-0.037,-0.078], mat.black);
  cyl('Fire selector', 0.011,0.008, [-0.043,-0.02,0.015], mat.black, 8, [0,0,Math.PI/2]);
  box('Charging handle spine', [0.042,0.012,0.062], [0,0.065,0.02], mat.black);
  box('Charging handle ears', [0.071,0.009,0.021], [0,0.065,0.041], mat.black);
  for (const side of [-1,1]) {
    box(`Receiver raised strip ${side}`, [0.004,0.009,0.235], [side*0.040,0.036,-0.10], mat.black);
    box(`Receiver pin ${side} forward`, [0.005,0.012,0.012], [side*0.042,-0.044,-0.17], mat.steel);
    box(`Receiver pin ${side} rear`, [0.005,0.012,0.012], [side*0.042,-0.044,0.015], mat.steel);
  }

  // Four-sided modular handguard with visible gaps and inset vent strips.
  box('Handguard core', [0.068,0.066,0.245], [0,0.004,-0.385], mat.black);
  box('Handguard top', [0.078,0.013,0.256], [0,0.044,-0.385], mat.tan);
  box('Handguard bottom', [0.071,0.012,0.233], [0,-0.040,-0.385], mat.tanShadow);
  for (const side of [-1,1]) {
    box(`Handguard side ${side}`, [0.012,0.057,0.235], [side*0.037,0.001,-0.385], mat.tan);
    box(`Side rail ${side}`, [0.009,0.018,0.22], [side*0.046,0.0,-0.384], mat.tanShadow);
    for (let i=0;i<4;i++) {
      const z=-0.485+i*0.058;
      box(`Vent dark ${side}-${i}`, [0.003,0.019,0.032], [side*0.044,0.024,z], mat.black);
      box(`Rail tooth ${side}-${i}`, [0.006,0.022,0.018], [side*0.052,0,z], mat.tanLight);
    }
  }
  box('Top picatinny spine', [0.052,0.012,0.478], [0,0.065,-0.218], mat.black);
  for (let i=0;i<12;i++) box(`Rail tooth ${i}`, [0.065,0.008,0.012], [0,0.074,-0.43+i*0.039], mat.receiverEdge);
  box('Foregrip clamp', [0.065,0.015,0.055], [0,-0.049,-0.389], mat.black);
  box('Vertical foregrip', [0.043,0.087,0.048], [0,-0.096,-0.389], mat.rubber);
  box('Foregrip end cap', [0.047,0.013,0.050], [0,-0.144,-0.389], mat.tanShadow);
  for (let i=0;i<3;i++) box(`Foregrip rib ${i}`, [0.046,0.006,0.051], [0,-0.074-i*0.021,-0.389], mat.tanShadow);

  // Eight-sided barrel and slotted flash hider keep the end readable in silhouette.
  cyl('Exposed barrel', 0.018,0.167, [0,0.009,-0.555], mat.black);
  cyl('Gas block', 0.026,0.041, [0,0.009,-0.508], mat.receiver);
  cyl('Flash hider body', 0.025,0.064, [0,0.009,-0.630], mat.steel);
  cyl('Muzzle bore', 0.013,0.004, [0,0.009,-0.664], mat.port);
  for (const side of [-1,1]) box(`Flash hider slot ${side}`, [0.003,0.007,0.026], [side*0.024,0.012,-0.636], mat.port);

  // Low-profile iron sights and a compact red-dot housing: MW2-era accessory mix.
  box('Rear sight foot', [0.055,0.017,0.057], [0,0.082,0.032], mat.black);
  for (const side of [-1,1]) box(`Rear sight wing ${side}`, [0.011,0.042,0.017], [side*0.022,0.106,0.029], mat.black);
  box('Rear sight bridge', [0.055,0.008,0.016], [0,0.126,0.029], mat.receiverEdge);
  box('Front sight base', [0.060,0.016,0.042], [0,0.082,-0.518], mat.black);
  for (const side of [-1,1]) box(`Front sight wing ${side}`, [0.010,0.032,0.015], [side*0.021,0.105,-0.518], mat.black);
  box('Front sight blade', [0.009,0.040,0.010], [0,0.110,-0.518], mat.steel);
  box('Optic clamp', [0.056,0.016,0.065], [0,0.083,-0.118], mat.black);
  box('Optic riser', [0.036,0.023,0.042], [0,0.100,-0.118], mat.receiverEdge);
  box('Optic body', [0.067,0.062,0.067], [0,0.142,-0.118], mat.black);
  box('Optic top hood', [0.071,0.012,0.075], [0,0.178,-0.118], mat.receiverEdge);
  for (const side of [-1,1]) box(`Optic hood chamfer ${side}`, [0.010,0.053,0.068], [side*0.035,0.145,-0.118], mat.receiverEdge);
  box('Optic lens front', [0.049,0.045,0.003], [0,0.142,-0.154], mat.lens);
  box('Optic lens rear', [0.049,0.045,0.003], [0,0.142,-0.082], mat.port);
  cyl('Optic brightness knob', 0.014,0.012, [0.043,0.151,-0.118], mat.tanShadow, 8, [0,0,Math.PI/2]);

  // Magazine is canted in two stages; ribs and baseplate break up the slab.
  box('Magazine well', [0.066,0.036,0.091], [0,-0.076,-0.103], mat.black);
  box('Magazine upper', [0.050,0.089,0.066], [0,-0.132,-0.116], mat.receiver, [-0.12,0,0]);
  box('Magazine lower', [0.051,0.077,0.065], [0,-0.201,-0.106], mat.receiver, [0.13,0,0]);
  box('Magazine floorplate', [0.060,0.016,0.077], [0,-0.245,-0.103], mat.tanShadow, [0.13,0,0]);
  for (let i=0;i<3;i++) for (const side of [-1,1]) box(`Magazine rib ${side}-${i}`, [0.004,0.008,0.059], [side*0.027,-0.13-i*0.029,-0.11], mat.steel);
  box('Trigger guard front', [0.008,0.045,0.009], [0,-0.092,-0.024], mat.black);
  box('Trigger guard bottom', [0.008,0.008,0.088], [0,-0.111,0.019], mat.black);
  box('Trigger', [0.007,0.025,0.006], [0,-0.085,0.006], mat.steel, [-0.2,0,0]);
  box('Pistol grip', [0.052,0.119,0.058], [0,-0.114,0.055], mat.rubber, [-0.25,0,0]);
  box('Pistol grip cap', [0.055,0.012,0.063], [0,-0.172,0.070], mat.tanShadow, [-0.25,0,0]);
  for (const side of [-1,1]) box(`Grip texture field ${side}`, [0.003,0.065,0.037], [side*0.028,-0.113,0.055], mat.tanShadow, [-0.25,0,0]);

  // Collapsible stock is open underneath, with rails, adjustment marks and pad.
  cyl('Buffer tube', 0.022,0.214, [0,0.008,0.151], mat.black);
  box('Stock cheek weld', [0.075,0.035,0.186], [0,0.038,0.156], mat.tan);
  for (const side of [-1,1]) {
    box(`Stock slide ${side}`, [0.016,0.036,0.175], [side*0.028,-0.020,0.159], mat.tanShadow);
    box(`Stock rear web ${side}`, [0.012,0.076,0.030], [side*0.030,-0.028,0.236], mat.tan);
    for (let i=0;i<3;i++) box(`Stock adjustment notch ${side}-${i}`, [0.003,0.009,0.015], [side*0.038,-0.005,0.100+i*0.038], mat.black);
  }
  box('Stock latch', [0.063,0.011,0.035], [0,-0.062,0.182], mat.black);
  box('Buttpad frame', [0.079,0.121,0.027], [0,-0.008,0.254], mat.tanShadow);
  box('Buttpad rubber', [0.084,0.124,0.014], [0,-0.008,0.272], mat.rubber);
  for (let i=0;i<4;i++) box(`Buttpad tread ${i}`, [0.075,0.005,0.002], [0,-0.052+i*0.028,0.280], mat.black);

  anchor('Sight', [0,0.142,-0.118]);
  anchor('Stock', [0,-0.005,0.200]);
  anchor('Grip', [0,-0.095,0.055]);
  anchor('Barrel', [0,0.009,-0.555]);
  anchor('Muzzle', [0,0.009,-0.669]);
  anchor('Eject', [0.055,0.024,-0.09]);
  root.userData.meshCount = count;
  root.userData.description = 'AR-7 voxel tactical carbine';
  return root;
}
