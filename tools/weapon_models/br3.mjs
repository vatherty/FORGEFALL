/** BR-3 Trident: voxel bullpup burst rifle, forward -Z. */
export function buildBr3(THREE) {
  const g = new THREE.Group();
  g.name = 'VM_br3';
  const m = {
    dark: new THREE.MeshStandardMaterial({color:0x242729,roughness:.81,metalness:.28}),
    metal: new THREE.MeshStandardMaterial({color:0x41494b,roughness:.66,metalness:.46}),
    edge: new THREE.MeshStandardMaterial({color:0x697275,roughness:.58,metalness:.53}),
    sand: new THREE.MeshStandardMaterial({color:0x9b8e70,roughness:.9,metalness:.08}),
    sandDark: new THREE.MeshStandardMaterial({color:0x6f6654,roughness:.91,metalness:.08}),
    sandLight: new THREE.MeshStandardMaterial({color:0xb3a585,roughness:.87,metalness:.07}),
    rubber: new THREE.MeshStandardMaterial({color:0x1b1d1b,roughness:.98}),
    void: new THREE.MeshStandardMaterial({color:0x101315,roughness:.8,metalness:.2}),
    lens: new THREE.MeshStandardMaterial({color:0x42251c,roughness:.3,metalness:.66,emissive:0x170401}),
    amber: new THREE.MeshStandardMaterial({color:0xe17d29,roughness:.36,metalness:.1,emissive:0xb95408,emissiveIntensity:.7}),
  };
  let meshes=0;
  function b(name,size,pos,material,rot) {
    const o=new THREE.Mesh(new THREE.BoxGeometry(...size),material);
    o.name=name;o.position.set(...pos);if(rot)o.rotation.set(...rot);
    o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o;
  }
  function c(name,r,len,pos,material,sides=8,rot=[Math.PI/2,0,0]) {
    const o=new THREE.Mesh(new THREE.CylinderGeometry(r,r,len,sides),material);
    o.name=name;o.position.set(...pos);o.rotation.set(...rot);
    o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o;
  }
  function silhouette(name,points,width,material) {
    const s=new THREE.Shape();s.moveTo(points[0][0],points[0][1]);
    for(let i=1;i<points.length;i++)s.lineTo(points[i][0],points[i][1]);s.closePath();
    const geo=new THREE.ExtrudeGeometry(s,{depth:width,bevelEnabled:false});
    geo.rotateY(-Math.PI/2);geo.translate(width/2,0,0);
    const o=new THREE.Mesh(geo,material);o.name=name;o.castShadow=true;o.receiveShadow=true;
    g.add(o);meshes++;return o;
  }
  function socket(name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);g.add(o)}

  // Bullpup body: broad high rear, vented tapered nose, mag behind the grip.
  silhouette('Continuous armored shell',[
    [-.475,.014],[-.422,.048],[-.27,.055],[-.22,.073],[-.11,.067],[-.073,.051],
    [.14,.05],[.239,.026],[.246,-.059],[.19,-.093],[.13,-.087],
    [.052,-.038],[-.008,-.038],[-.097,-.074],[-.211,-.048],[-.415,-.049]
  ],.078,m.sand);
  silhouette('Inset lower chassis',[
    [-.355,-.037],[-.21,-.044],[-.139,-.068],[-.08,-.071],[-.018,-.035],
    [.052,-.041],[.111,-.083],[.177,-.09],[.164,-.109],[.075,-.108],
    [.007,-.068],[-.088,-.108],[-.221,-.084],[-.375,-.064]
  ],.066,m.dark);
  for(const side of [-1,1]) {
    b(`Long shell edge ${side}`,[.006,.011,.405],[side*.042,.046,-.285],m.sandLight);
    b(`Rear armor panel ${side}`,[.004,.054,.147],[side*.042,-.008,.132],m.sandDark);
    b(`Receiver panel ${side}`,[.004,.045,.158],[side*.043,.002,-.105],m.metal);
    b(`Receiver line ${side}`,[.005,.006,.145],[side*.047,.028,-.105],m.edge);
    b(`Rear lower cheek ${side}`,[.005,.025,.13],[side*.045,-.072,.121],m.sandDark);
    for(let i=0;i<3;i++) {
      const z=-.394+i*.062;
      b(`Forward cooling vent ${side}-${i}`,[.003,.021,.039],[side*.044,.016,z],m.void);
      b(`Vent leading lip ${side}-${i}`,[.005,.024,.006],[side*.047,.016,z-.021],m.edge);
    }
  }
  b('Nose block',[.066,.073,.06],[0,.007,-.449],m.metal);
  b('Nose lower skid',[.07,.013,.084],[0,-.037,-.438],m.sandDark);
  b('Long top monolithic rail',[.056,.014,.35],[0,.065,-.325],m.dark);
  for(let i=0;i<9;i++)b(`Rail bridge ${i}`,[.065,.008,.014],[0,.076,-.459+i*.039],m.edge);

  // Exposed long precision barrel with distinctive three-port muzzle brake.
  c('Precision barrel',.016,.247,[0,.009,-.568],m.dark);
  c('Barrel collar',.026,.038,[0,.009,-.495],m.edge);
  c('Muzzle brake',.025,.067,[0,.009,-.676],m.metal);
  c('Dark bore',.013,.004,[0,.009,-.712],m.void);
  for(const side of [-1,1])for(let i=0;i<3;i++)
    b(`Brake port ${side}-${i}`,[.004,.014,.01],[side*.025,.009,-.698+i*.019],m.void);
  b('Front blade mount',[.046,.018,.041],[0,.086,-.484],m.dark);
  b('Front blade',[.009,.031,.009],[0,.111,-.485],m.edge);

  // Integral carry handle has a real sighting aperture visible from the side.
  b('Carry handle front pillar',[.056,.058,.031],[0,.098,-.223],m.dark);
  b('Carry handle rear pillar',[.056,.056,.036],[0,.097,.015],m.dark);
  b('Carry handle upper beam',[.061,.024,.284],[0,.132,-.105],m.metal);
  b('Carry handle raised spine',[.045,.011,.198],[0,.149,-.105],m.sandDark);
  for(const side of [-1,1]) {
    b(`Handle side relief ${side}`,[.005,.023,.198],[side*.033,.112,-.105],m.edge);
    b(`Handle rear hook ${side}`,[.009,.03,.019],[side*.029,.119,.026],m.sandDark);
  }
  b('Optic low clamp',[.052,.014,.067],[0,.163,-.09],m.dark);
  b('Burst reflex optic',[.068,.052,.067],[0,.193,-.09],m.dark);
  b('Optic crown',[.074,.012,.074],[0,.224,-.09],m.edge);
  b('Optic front glass',[.052,.036,.003],[0,.193,-.125],m.lens);
  b('Optic rear glass',[.052,.036,.003],[0,.193,-.055],m.void);
  c('Optic adjustment',.012,.009,[.042,.2,-.09],m.sandDark,8,[0,0,Math.PI/2]);

  // Forward grip and open trigger guard differentiate the control area.
  b('Foregrip collar',[.068,.014,.066],[0,-.048,-.343],m.dark);
  b('Angled foregrip',[.041,.092,.052],[0,-.096,-.356],m.rubber,[-.2,0,0]);
  b('Foregrip toe',[.049,.014,.059],[0,-.143,-.346],m.sandDark,[-.2,0,0]);
  for(let i=0;i<3;i++)b(`Foregrip grip line ${i}`,[.045,.005,.053],[0,-.079-i*.021,-.354],m.edge,[-.2,0,0]);
  b('Pistol grip neck',[.052,.034,.052],[0,-.082,-.044],m.dark);
  b('Pistol grip',[.049,.126,.061],[0,-.137,-.032],m.rubber,[-.19,0,0]);
  b('Pistol grip heel',[.056,.017,.067],[0,-.2,-.019],m.sandDark,[-.19,0,0]);
  for(const side of [-1,1])b(`Grip inset ${side}`,[.004,.068,.037],[side*.026,-.138,-.029],m.sandDark,[-.19,0,0]);
  b('Trigger guard front',[.007,.041,.008],[0,-.085,-.127],m.dark);
  b('Trigger guard floor',[.008,.008,.072],[0,-.105,-.092],m.dark);
  b('Trigger',[.007,.023,.007],[0,-.084,-.089],m.edge);

  // Rear-loading magazine and high cheek stock show the bullpup function.
  b('Magazine well',[.066,.028,.069],[0,-.087,.135],m.dark);
  b('Magazine upper',[.053,.072,.068],[0,-.133,.138],m.metal,[.17,0,0]);
  b('Magazine lower',[.056,.064,.069],[0,-.193,.151],m.metal,[.17,0,0]);
  b('Magazine base',[.064,.016,.078],[0,-.226,.158],m.sandDark,[.17,0,0]);
  for(const side of [-1,1])for(let i=0;i<3;i++)
    b(`Magazine stamping ${side}-${i}`,[.004,.007,.057],[side*.029,-.145-i*.022,.146],m.edge,[.17,0,0]);
  b('Rear cheek pad',[.075,.024,.151],[0,.056,.143],m.rubber);
  b('Buttplate foundation',[.077,.119,.031],[0,-.016,.238],m.sandDark);
  b('Rubber buttpad',[.082,.121,.015],[0,-.016,.26],m.rubber);
  for(let i=0;i<4;i++)b(`Buttpad rib ${i}`,[.072,.005,.003],[0,-.06+i*.03,.269],m.dark);

  // Physical side controls and three amber burst markers.
  b('Right ejection recess',[.003,.034,.075],[.045,.008,.035],m.void);
  b('Right ejection bolt',[.002,.014,.046],[.047,.013,.035],m.edge);
  c('Left selector',.011,.006,[-.047,-.027,-.102],m.dark,8,[0,0,Math.PI/2]);
  for(let i=0;i<3;i++)b(`Burst lamp ${i+1}`,[.006,.012,.012],[.049,.012,-.173+i*.028],m.amber);
  b('Charging latch',[.022,.025,.025],[.052,.049,-.156],m.dark);

  socket('Sight',[0,.193,-.09]);
  socket('Stock',[0,-.005,.2]);
  socket('Grip',[0,-.137,-.032]);
  socket('Barrel',[0,.009,-.568]);
  socket('Muzzle',[0,.009,-.716]);
  socket('Eject',[.052,.018,.035]);
  g.userData.meshCount=meshes;
  g.userData.description='BR-3 Trident voxel bullpup burst rifle';
  return g;
}
