// Modular late-2000s tactical / voxel weapon attachments.
// All groups have their attachment point at local (0, 0, 0), forward -Z.
// Optics center on the sight line; muzzles extend forward; magazines hang
// below; stocks extend rearward. A caller may attach each group to a named
// Object3D anchor, then apply an anchor-specific offset when desired.

function palette(THREE, accentColor = 0x9a8e69) {
  return {
    black: new THREE.MeshStandardMaterial({ color: 0x1b2223, roughness: 0.78, metalness: 0.35 }),
    dark: new THREE.MeshStandardMaterial({ color: 0x313b3b, roughness: 0.67, metalness: 0.51 }),
    steel: new THREE.MeshStandardMaterial({ color: 0x5b6764, roughness: 0.58, metalness: 0.55 }),
    tan: new THREE.MeshStandardMaterial({ color: 0x817a61, roughness: 0.93, metalness: 0.04 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x111717, roughness: 1 }),
    glass: new THREE.MeshStandardMaterial({ color: 0x36545a, roughness: 0.2, metalness: 0.13, emissive: 0x12252b, emissiveIntensity: 0.22 }),
    accent: new THREE.MeshStandardMaterial({ color: accentColor, roughness: 0.72, metalness: 0.19 }),
  };
}

function builder(THREE, name, accentColor) {
  const group = new THREE.Group();
  group.name = name;
  const mat = palette(THREE, accentColor);
  const box = (name, size, position, material, rotation) => {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), mat[material]);
    mesh.name = name;
    mesh.position.set(...position);
    if (rotation) mesh.rotation.set(...rotation);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    group.add(mesh);
    return mesh;
  };
  const oct = (name, radius, length, position, material, axis = 'z') => {
    const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, 8), mat[material]);
    mesh.name = name;
    if (axis === 'z') mesh.rotation.x = Math.PI / 2;
    else if (axis === 'x') mesh.rotation.z = Math.PI / 2;
    mesh.position.set(...position);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    group.add(mesh);
    return mesh;
  };
  return { group, box, oct };
}

/** Build an iron, reflex, or magnified scope centered on its sight line. */
export function buildOptic(THREE, options = {}) {
  const type = options.type ?? 'reflex';
  const { group, box, oct } = builder(THREE, `Optic ${type}`, options.accentColor);
  if (type === 'iron') {
    box('rear iron base', [0.05, 0.014, 0.021], [0, -0.03, 0.052], 'black');
    box('rear iron bridge', [0.046, 0.009, 0.014], [0, -0.012, 0.052], 'steel');
    for (const s of [-1, 1]) {
      box(`rear iron wing ${s}`, [0.011, 0.031, 0.014], [s * 0.021, 0.003, 0.052], 'black');
      box(`rear index ${s}`, [0.004, 0.005, 0.002], [s * 0.021, 0.012, 0.043], 'accent');
    }
    box('front iron pedestal', [0.039, 0.021, 0.019], [0, -0.025, -0.09], 'black');
    box('front iron blade', [0.01, 0.027, 0.011], [0, 0.001, -0.09], 'steel');
    box('front insert', [0.005, 0.007, 0.002], [0, 0.012, -0.097], 'accent');
  } else if (type === 'scope') {
    box('scope rail foot', [0.05, 0.012, 0.175], [0, -0.056, 0.015], 'black');
    for (const [i, z] of [-0.053, 0.067].entries()) {
      box(`scope ring post ${i}`, [0.028, 0.05, 0.027], [0, -0.026, z], 'dark');
      box(`scope ring cap ${i}`, [0.068, 0.012, 0.032], [0, 0.001, z], 'steel');
    }
    oct('scope tube', 0.029, 0.208, [0, 0, 0.013], 'black');
    oct('objective bell', 0.042, 0.061, [0, 0, -0.122], 'dark');
    oct('objective rim', 0.044, 0.01, [0, 0, -0.156], 'steel');
    box('objective lens', [0.055, 0.055, 0.002], [0, 0, -0.162], 'glass');
    oct('ocular bell', 0.036, 0.046, [0, 0, 0.126], 'dark');
    oct('rubber eyecup', 0.038, 0.017, [0, 0, 0.159], 'rubber');
    box('elevation turret', [0.032, 0.031, 0.032], [0, 0.044, 0.012], 'black');
    box('turret index', [0.005, 0.003, 0.013], [0, 0.061, 0.012], 'accent');
    box('windage turret', [0.023, 0.028, 0.028], [0.043, 0, 0.012], 'black');
  } else if (type === 'reflex') {
    box('reflex rail foot', [0.057, 0.013, 0.082], [0, -0.046, 0.007], 'black');
    box('reflex riser', [0.032, 0.029, 0.065], [0, -0.023, 0.007], 'dark');
    box('reflex lower housing', [0.064, 0.014, 0.072], [0, -0.006, 0.007], 'steel');
    for (const s of [-1, 1]) {
      box(`reflex upright ${s}`, [0.014, 0.057, 0.053], [s * 0.027, 0.025, -0.003], 'black');
      box(`reflex side inset ${s}`, [0.003, 0.037, 0.034], [s * 0.035, 0.025, -0.003], 'dark');
    }
    box('reflex top arch', [0.067, 0.012, 0.054], [0, 0.058, -0.003], 'black');
    box('reflex front glass', [0.042, 0.039, 0.002], [0, 0.025, -0.03], 'glass');
    box('reflex reticle', [0.004, 0.004, 0.002], [0, 0.025, -0.034], 'accent');
    box('brightness dial', [0.014, 0.016, 0.019], [0.041, 0.002, 0.026], 'steel');
  } else {
    throw new RangeError(`Unsupported optic type: ${type}`);
  }
  return group;
}

/** Build a brake, suppressor, or oversized launcher cup from the muzzle face. */
export function buildMuzzle(THREE, options = {}) {
  const type = options.type ?? 'brake';
  const { group, box, oct } = builder(THREE, `Muzzle ${type}`, options.accentColor);
  if (type === 'brake') {
    oct('brake root collar', 0.027, 0.019, [0, 0, -0.009], 'steel');
    oct('brake body', 0.032, 0.069, [0, 0, -0.05], 'black');
    box('brake front face', [0.048, 0.048, 0.005], [0, 0, -0.088], 'steel');
    box('brake bore', [0.02, 0.02, 0.002], [0, 0, -0.093], 'rubber');
    for (const s of [-1, 1]) {
      box(`brake port ${s}`, [0.003, 0.018, 0.021], [s * 0.032, 0, -0.055], 'rubber');
    }
  } else if (type === 'suppressor') {
    oct('suppressor adapter', 0.022, 0.021, [0, 0, -0.01], 'steel');
    oct('suppressor body', 0.037, 0.173, [0, 0, -0.107], 'black');
    oct('suppressor rear cap', 0.041, 0.014, [0, 0, -0.029], 'dark');
    oct('suppressor front cap', 0.041, 0.014, [0, 0, -0.19], 'steel');
    box('suppressor bore', [0.017, 0.017, 0.002], [0, 0, -0.199], 'rubber');
    for (let i = 0; i < 4; i++) {
      oct(`suppressor cooling ring ${i}`, 0.038, 0.004, [0, 0, -0.059 - i * 0.027], 'dark');
    }
  } else if (type === 'launcher_cup') {
    oct('cup mounting collar', 0.025, 0.032, [0, 0, -0.016], 'steel');
    box('cup neck', [0.061, 0.061, 0.052], [0, 0, -0.061], 'dark');
    box('flared cup body', [0.116, 0.116, 0.112], [0, 0, -0.143], 'tan');
    box('cup front lip', [0.128, 0.128, 0.015], [0, 0, -0.208], 'steel');
    box('cup open mouth', [0.094, 0.094, 0.002], [0, 0, -0.218], 'rubber');
    for (const s of [-1, 1]) {
      box(`cup side brace ${s}`, [0.011, 0.057, 0.096], [s * 0.06, 0, -0.139], 'black');
      box(`cup warning mark ${s}`, [0.003, 0.014, 0.045], [s * 0.067, 0.04, -0.146], 'accent');
    }
  } else {
    throw new RangeError(`Unsupported muzzle type: ${type}`);
  }
  return group;
}

/** Build a box or drum magazine with its feed point at local origin. */
export function buildMagazine(THREE, options = {}) {
  const type = options.type ?? 'box';
  const { group, box, oct } = builder(THREE, `Magazine ${type}`, options.accentColor);
  box('magazine feed lips', [0.051, 0.018, 0.067], [0, -0.009, 0], 'steel');
  if (type === 'box') {
    box('box magazine neck', [0.053, 0.042, 0.071], [0, -0.031, 0.002], 'black');
    box('box magazine body', [0.059, 0.128, 0.079], [0, -0.109, 0.011], 'dark', [0.07, 0, 0]);
    box('box magazine floorplate', [0.068, 0.015, 0.085], [0, -0.174, 0.02], 'tan');
    for (const s of [-1, 1]) {
      for (let i = 0; i < 3; i++) {
        box(`box mag rib ${s} ${i}`, [0.004, 0.094, 0.006], [s * 0.031, -0.108, -0.013 + i * 0.026], 'black');
      }
      box(`box mag witness slit ${s}`, [0.004, 0.035, 0.007], [s * 0.032, -0.118, 0.043], 'accent');
    }
  } else if (type === 'drum') {
    box('drum magazine neck', [0.054, 0.047, 0.068], [0, -0.034, 0], 'black');
    oct('drum round body', 0.084, 0.069, [0, -0.127, 0.026], 'dark', 'x');
    for (const s of [-1, 1]) {
      box(`drum face panel ${s}`, [0.004, 0.109, 0.109], [s * 0.037, -0.127, 0.026], 'black');
      box(`drum center hub ${s}`, [0.008, 0.026, 0.026], [s * 0.042, -0.127, 0.026], 'steel');
      box(`drum face tick top ${s}`, [0.004, 0.025, 0.007], [s * 0.041, -0.084, 0.026], 'accent');
    }
    box('drum lower bumper', [0.074, 0.014, 0.07], [0, -0.208, 0.026], 'rubber');
  } else {
    throw new RangeError(`Unsupported magazine type: ${type}`);
  }
  return group;
}

/** Build a solid or folded rear stock extending toward +Z. */
export function buildStock(THREE, options = {}) {
  const type = options.type ?? 'solid';
  const { group, box } = builder(THREE, `Stock ${type}`, options.accentColor);
  box('stock mount', [0.056, 0.061, 0.031], [0, 0, 0.014], 'steel');
  if (type === 'solid') {
    box('stock spine', [0.058, 0.045, 0.176], [0, 0.017, 0.107], 'dark');
    box('stock lower beam', [0.052, 0.029, 0.148], [0, -0.047, 0.12], 'black');
    box('stock side shell left', [0.009, 0.079, 0.116], [-0.032, -0.009, 0.134], 'tan');
    box('stock side shell right', [0.009, 0.079, 0.116], [0.032, -0.009, 0.134], 'tan');
    box('stock cheek rest', [0.072, 0.016, 0.124], [0, 0.05, 0.133], 'rubber');
    box('stock heel', [0.071, 0.083, 0.054], [0, -0.016, 0.207], 'dark');
    box('stock buttpad', [0.077, 0.096, 0.024], [0, -0.016, 0.248], 'rubber');
    for (let i = 0; i < 3; i++) {
      box(`buttpad grip rib ${i}`, [0.078, 0.005, 0.006], [0, -0.051 + i * 0.029, 0.263], 'steel');
    }
  } else if (type === 'folding') {
    box('folding stock hinge', [0.069, 0.072, 0.037], [0, 0, 0.045], 'dark');
    box('folding hinge pin', [0.077, 0.014, 0.014], [0, 0, 0.052], 'steel');
    for (const s of [-1, 1]) {
      box(`stock strut ${s}`, [0.013, 0.016, 0.17], [s * 0.028, 0.025, 0.136], 'steel');
      box(`stock lower strut ${s}`, [0.012, 0.015, 0.123], [s * 0.028, -0.038, 0.156], 'black');
    }
    box('folding cheek pad', [0.066, 0.022, 0.126], [0, 0.044, 0.149], 'tan');
    box('folding stock rear plate', [0.072, 0.089, 0.022], [0, -0.012, 0.236], 'dark');
    box('folding rubber buttpad', [0.079, 0.094, 0.021], [0, -0.012, 0.258], 'rubber');
  } else {
    throw new RangeError(`Unsupported stock type: ${type}`);
  }
  return group;
}

/** Small, optional surface detail: heat shield, hazard stripe, or ID stencil. */
export function buildAccent(THREE, options = {}) {
  const type = options.type ?? 'heat_shield';
  const { group, box } = builder(THREE, `Accent ${type}`, options.accentColor);
  if (type === 'heat_shield') {
    box('heat shield backing', [0.074, 0.009, 0.14], [0, 0, 0], 'black');
    for (let i = 0; i < 4; i++) {
      box(`heat vent ${i}`, [0.063, 0.003, 0.016], [0, 0.007, -0.052 + i * 0.034], 'dark');
    }
  } else if (type === 'hazard_stripe') {
    box('hazard base', [0.07, 0.003, 0.11], [0, 0, 0], 'black');
    for (let i = 0; i < 4; i++) {
      box(`hazard stripe ${i}`, [0.068, 0.004, 0.01], [0, 0.004, -0.039 + i * 0.024], 'accent', [0, 0.24, 0]);
    }
  } else if (type === 'stencil') {
    box('stencil plate', [0.068, 0.003, 0.09], [0, 0, 0], 'tan');
    box('stencil main mark', [0.041, 0.004, 0.008], [0, 0.004, -0.017], 'black');
    box('stencil number left', [0.008, 0.004, 0.012], [-0.017, 0.004, 0.011], 'black');
    box('stencil number right', [0.008, 0.004, 0.012], [0.017, 0.004, 0.011], 'black');
  } else {
    throw new RangeError(`Unsupported accent type: ${type}`);
  }
  return group;
}
