/** Raptor prototype claw: compact voxel weapon with three energized tines. */
export function buildRaptor(THREE) {
  const g=new THREE.Group();g.name='VM_raptor';
  const mat={
    shell:new THREE.MeshStandardMaterial({color:0x4b5151,roughness:.67,metalness:.44}),
    edge:new THREE.MeshStandardMaterial({color:0x858b83,roughness:.51,metalness:.62}),
    dark:new THREE.MeshStandardMaterial({color:0x202425,roughness:.8,metalness:.29}),
    void:new THREE.MeshStandardMaterial({color:0x101515,roughness:.75,metalness:.3}),
    tan:new THREE.MeshStandardMaterial({color:0x8e8064,roughness:.9,metalness:.08}),
    tanDark:new THREE.MeshStandardMaterial({color:0x665d4d,roughness:.93,metalness:.06}),
    rubber:new THREE.MeshStandardMaterial({color:0x252522,roughness:.98}),
    glow:new THREE.MeshStandardMaterial({color:0xff8b32,roughness:.36,metalness:.17,emissive:0xf26708,emissiveIntensity:1.65}),
    glowDim:new THREE.MeshStandardMaterial({color:0x9b4c1d,roughness:.45,metalness:.28,emissive:0x572000,emissiveIntensity:.8}),
  };
  let meshes=0;
  function box(name,size,pos,m,rotation){const o=new THREE.Mesh(new THREE.BoxGeometry(...size),m);o.name=name;o.position.set(...pos);if(rotation)o.rotation.set(...rotation);o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function cyl(name,r,len,pos,m,sides=8,rotation=[Math.PI/2,0,0]){const o=new THREE.Mesh(new THREE.CylinderGeometry(r,r,len,sides),m);o.name=name;o.position.set(...pos);o.rotation.set(...rotation);o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function profile(name,points,width,x,m){const s=new THREE.Shape();s.moveTo(points[0][0],points[0][1]);for(let i=1;i<points.length;i++)s.lineTo(points[i][0],points[i][1]);s.closePath();const geo=new THREE.ExtrudeGeometry(s,{depth:width,bevelEnabled:false});geo.rotateY(-Math.PI/2);geo.translate(x+width/2,0,0);const o=new THREE.Mesh(geo,m);o.name=name;o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function anchor(name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);g.add(o)}

  // Wrist cuff: machined frame over a wrapped forearm, with a strap opening.
  box('Inner wrist chassis',[.083,.080,.150],[0,-.003,.032],mat.dark);
  box('Upper armored carapace',[.105,.037,.139],[0,.059,.024],mat.shell);
  box('Lower mounting saddle',[.097,.024,.155],[0,-.062,.034],mat.tanDark);
  for(const side of [-1,1]){
    box(`Outer side plate ${side}`,[.016,.077,.148],[side*.05,.001,.027],mat.tan);
    box(`Wrist side lip ${side}`,[.005,.017,.153],[side*.059,.047,.027],mat.edge);
    box(`Wrist strap buckle ${side}`,[.007,.034,.025],[side*.061,-.031,.078],mat.dark);
    box(`Upper shell vent ${side}`,[.005,.012,.062],[side*.055,.067,-.006],mat.void);
    for(let i=0;i<3;i++)box(`Armor grip notch ${side}-${i}`,[.005,.015,.007],[side*.06,-.017,.064-i*.033],mat.tanDark);
  }
  box('Rear wrist cuff',[.108,.094,.028],[0,-.006,.118],mat.rubber);
  box('Rear cuff lock',[.112,.021,.031],[0,.049,.118],mat.tanDark);
  box('Front cuff collar',[.107,.093,.025],[0,-.004,-.064],mat.shell);
  box('Hand trigger grip',[.060,.118,.058],[0,-.107,.062],mat.rubber,[-.13,0,0]);
  box('Grip base',[.065,.015,.065],[0,-.165,.071],mat.tanDark,[-.13,0,0]);
  for(let i=0;i<4;i++)box(`Grip rib ${i}`,[.064,.006,.062],[0,-.076-i*.023,.063],mat.tanDark,[-.13,0,0]);
  box('Control trigger',[.012,.033,.012],[0,-.076,-.005],mat.edge);
  box('Control guard',[.059,.009,.093],[0,-.103,-.012],mat.shell);

  // Shielded orange cell: lights are small relative to the metal, keeping the
  // visual closer to a military prototype than a neon fantasy prop.
  box('Power cell cradle',[.079,.074,.085],[0,.013,-.091],mat.dark);
  box('Power cell front aperture',[.063,.059,.006],[0,.014,-.138],mat.edge);
  box('Power cell window',[.044,.043,.006],[0,.014,-.143],mat.glow);
  box('Power cell rear window',[.038,.038,.004],[0,.014,-.046],mat.glowDim);
  for(const side of [-1,1]){
    box(`Cell spine ${side}`,[.013,.065,.104],[side*.04,.017,-.09],mat.shell);
    box(`Cell side aperture ${side}`,[.004,.025,.052],[side*.048,.016,-.092],mat.glowDim);
    box(`Cell forward retainer ${side}`,[.018,.078,.017],[side*.052,.012,-.139],mat.edge);
    cyl(`Cell locking pin ${side}`,.009,.006,[side*.055,.041,-.077],mat.edge,8,[0,0,Math.PI/2]);
  }
  box('Cell overbridge',[.061,.018,.126],[0,.061,-.09],mat.shell);
  for(let i=0;i<4;i++)box(`Overbridge vent ${i}`,[.051,.003,.012],[0,.072,-.135+i*.026],mat.void);

  // Three claw tracks fan apart toward the muzzle. Segmented tips have a
  // sharp stepped silhouette and tiny emitter inserts at their ends.
  const tines=[
    {name:'Dorsal',x:0,y:.056,spread:0},
    {name:'Port',x:-.054,y:-.033,spread:-1},
    {name:'Starboard',x:.054,y:-.033,spread:1},
  ];
  for(const tine of tines){
    const {name,x,y,spread}=tine;
    box(`${name} root pivot`,[.036,.040,.053],[x*.72,y,-.154],mat.dark);
    box(`${name} rear beam`,[.027,.026,.101],[x,y,-.218],mat.shell);
    box(`${name} beam highlight`,[.028,.006,.086],[x,y+.017,-.215],mat.edge);
    box(`${name} beam groove`,[.030,.005,.055],[x,y-.015,-.221],mat.void);
    box(`${name} knee joint`,[.039,.038,.032],[x+spread*.008,y,-.278],mat.dark);
    profile(`${name} wedge tip`,[
      [-.285,y+.018],[-.337,y+.016],[-.354,y+.009],[-.373,y-.004],
      [-.353,y-.016],[-.302,y-.018],[-.285,y-.011]
    ],.027,x+spread*.013,mat.shell);
    box(`${name} tip edge`,[.026,.006,.056],[x+spread*.013,y+.015,-.329],mat.edge);
    box(`${name} emitter slit`,[.028,.009,.028],[x+spread*.013,y-.011,-.333],mat.glow);
    box(`${name} end cap`,[.028,.018,.011],[x+spread*.013,y,-.36],mat.glowDim);
    for(let i=0;i<2;i++)box(`${name} vent ${i}`,[.030,.006,.009],[x,y+.016,-.218-i*.025],mat.void);
  }
  // A central launch channel explains where the projectile emerges.
  box('Central channel housing',[.036,.036,.153],[0,.008,-.237],mat.dark);
  cyl('Central emitter',.011,.037,[0,.009,-.307],mat.glow);
  cyl('Emitter ring',.022,.013,[0,.009,-.319],mat.edge);
  cyl('Emitter bore',.008,.004,[0,.009,-.328],mat.void);

  // Tactical controls and optic index above the upper tine.
  box('Top sight rail',[.061,.012,.082],[0,.089,-.042],mat.dark);
  box('Sight rear notch',[.046,.026,.014],[0,.105,.002],mat.edge);
  box('Sight front blade',[.010,.030,.010],[0,.108,-.175],mat.edge);
  box('Top activation switch',[.027,.010,.036],[0,.082,.064],mat.tanDark);
  for(let i=0;i<3;i++)box(`Charge status ${i+1}`,[.012,.004,.01],[.032,.081,.065-i*.025],mat.glowDim);

  anchor('Sight',[0,.104,-.12]);
  anchor('Stock',[0,0,.05]);
  anchor('Grip',[0,-.107,.062]);
  anchor('Barrel',[0,.009,-.25]);
  anchor('Muzzle',[0,.009,-.383]);
  anchor('Eject',[0,.077,-.024]);
  g.userData.meshCount=meshes;
  g.userData.description='Raptor tactical prototype claw';
  return g;
}
