/** MW2-era voxel militia grunt. Feet at y=0, forward -Z. */
export function buildGrunt(THREE) {
  const root=new THREE.Group();root.name='Grunt';
  const body=new THREE.Group();body.name='BodyRoot';root.add(body);
  const mat={
    cloth:new THREE.MeshStandardMaterial({color:0x6f7467,roughness:.97}),
    clothShade:new THREE.MeshStandardMaterial({color:0x52594e,roughness:.99}),
    clothLight:new THREE.MeshStandardMaterial({color:0x88907b,roughness:.97}),
    armor:new THREE.MeshStandardMaterial({color:0x555b55,roughness:.87,metalness:.17}),
    armorEdge:new THREE.MeshStandardMaterial({color:0x7d8476,roughness:.79,metalness:.2}),
    tan:new THREE.MeshStandardMaterial({color:0x94866b,roughness:.94}),
    tanDark:new THREE.MeshStandardMaterial({color:0x695f4c,roughness:.96}),
    webbing:new THREE.MeshStandardMaterial({color:0x3b3f38,roughness:.94}),
    rubber:new THREE.MeshStandardMaterial({color:0x272b29,roughness:.99}),
    metal:new THREE.MeshStandardMaterial({color:0x636b69,roughness:.64,metalness:.42}),
    visor:new THREE.MeshStandardMaterial({color:0x272d2e,roughness:.34,metalness:.28}),
    skin:new THREE.MeshStandardMaterial({color:0x9b7861,roughness:.94}),
    lamp:new THREE.MeshStandardMaterial({color:0xd58c37,roughness:.55,emissive:0x4d2607,emissiveIntensity:.3}),
  };
  let meshes=0;
  function box(parent,name,size,pos,material,rot){const o=new THREE.Mesh(new THREE.BoxGeometry(...size),material);o.name=name;o.position.set(...pos);if(rot)o.rotation.set(...rot);o.castShadow=true;o.receiveShadow=true;parent.add(o);meshes++;return o}
  function prism(parent,name,points,width,x,material){const s=new THREE.Shape();s.moveTo(points[0][0],points[0][1]);for(let i=1;i<points.length;i++)s.lineTo(points[i][0],points[i][1]);s.closePath();const geo=new THREE.ExtrudeGeometry(s,{depth:width,bevelEnabled:false});geo.rotateY(-Math.PI/2);geo.translate(x+width/2,0,0);const o=new THREE.Mesh(geo,material);o.name=name;o.castShadow=true;o.receiveShadow=true;parent.add(o);meshes++;return o}
  function pivot(parent,name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);parent.add(o);return o}

  // Leg units are hinged at the hips; feet rest exactly on the root ground plane.
  for(const side of [-1,1]){
    const label=side<0?'L':'R';
    const hip=pivot(body,`Hip${label}`,[side*.152,.75,0]);
    box(hip,`Trouser ${label}`,[.243,.426,.269],[0,-.222,.013],mat.cloth);
    box(hip,`Front thigh fold ${label}`,[.18,.034,.007],[0,-.17,-.125],mat.clothLight);
    box(hip,`Outer cargo pocket ${label}`,[.02,.13,.145],[side*.127,-.246,.025],mat.clothShade);
    box(hip,`Cargo flap ${label}`,[.026,.023,.155],[side*.139,-.173,.022],mat.tanDark);
    box(hip,`Knee joint ${label}`,[.222,.064,.23],[0,-.423,.004],mat.clothShade);
    box(hip,`Knee shell ${label}`,[.202,.148,.044],[0,-.46,-.139],mat.armor);
    box(hip,`Knee shell top ${label}`,[.17,.021,.056],[0,-.391,-.14],mat.armorEdge);
    box(hip,`Knee strap ${label}`,[.248,.018,.238],[0,-.478,.012],mat.webbing);
    box(hip,`Lower trouser ${label}`,[.204,.23,.23],[0,-.582,.017],mat.clothShade);
    box(hip,`Shin guard ${label}`,[.175,.145,.039],[0,-.592,-.115],mat.armor);
    box(hip,`Boot ankle ${label}`,[.23,.13,.264],[0,-.677,.022],mat.rubber);
    box(hip,`Boot toe ${label}`,[.23,.065,.355],[0,-.718,-.071],mat.rubber);
    box(hip,`Boot toe cap ${label}`,[.235,.027,.109],[0,-.734,-.198],mat.armor);
    box(hip,`Boot sole ${label}`,[.244,.022,.37],[0,-.739,-.079],mat.webbing);
    for(let i=0;i<3;i++)box(hip,`Boot lace ${label}-${i}`,[.147,.005,.016],[0,-.622-i*.024,-.12],mat.tanDark);
  }

  // Chest silhouette: layered plate carrier over a broad cloth upper body.
  box(body,'Pelvis',[.476,.183,.286],[0,.79,.005],mat.clothShade);
  box(body,'Torso fatigues',[.52,.64,.322],[0,1.12,.015],mat.cloth);
  box(body,'Upper yoke',[.56,.105,.339],[0,1.408,.005],mat.clothShade);
  box(body,'Front plate carrier',[.485,.405,.091],[0,1.177,-.179],mat.armor);
  box(body,'Carrier top chest panel',[.432,.111,.105],[0,1.32,-.193],mat.armorEdge);
  box(body,'Carrier bottom flap',[.477,.054,.107],[0,.95,-.193],mat.tanDark);
  box(body,'Rear plate carrier',[.476,.389,.079],[0,1.173,.201],mat.armor);
  for(const side of [-1,1]){
    box(body,`Carrier side panel ${side}`,[.047,.332,.331],[side*.259,1.171,.012],mat.tanDark);
    box(body,`Shoulder harness ${side}`,[.081,.032,.427],[side*.168,1.453,.008],mat.webbing);
    box(body,`Harness front strap ${side}`,[.052,.30,.021],[side*.18,1.18,-.245],mat.tan);
    box(body,`Harness strap buckle ${side}`,[.069,.044,.026],[side*.18,1.296,-.26],mat.metal);
    box(body,`Hip webbing ${side}`,[.043,.102,.34],[side*.249,.854,.006],mat.webbing);
  }
  box(body,'Belt',[.537,.080,.351],[0,.84,.015],mat.webbing);
  box(body,'Belt buckle',[.071,.056,.029],[0,.845,-.179],mat.metal);
  for(const side of [-1,1]){
    box(body,`Belt utility pouch ${side}`,[.133,.136,.093],[side*.2,.823,-.18],mat.tanDark);
    box(body,`Belt pouch flap ${side}`,[.142,.034,.10],[side*.2,.89,-.182],mat.tan);
    box(body,`Chest ammo pouch ${side}`,[.13,.184,.082],[side*.125,1.147,-.274],mat.tan);
    box(body,`Chest pouch flap ${side}`,[.138,.036,.092],[side*.125,1.24,-.28],mat.tanDark);
    box(body,`Chest pouch strap ${side}`,[.026,.185,.006],[side*.125,1.146,-.321],mat.webbing);
  }
  box(body,'Center radio unit',[.11,.16,.087],[0,1.22,-.274],mat.webbing);
  box(body,'Radio screen',[.067,.049,.006],[0,1.241,-.323],mat.visor);
  box(body,'Radio button',[.018,.018,.007],[0,1.199,-.326],mat.lamp);

  // Backpack protrudes beyond the shoulders from side profile.
  box(body,'Pack main',[.383,.47,.209],[0,1.158,.303],mat.tanDark);
  box(body,'Pack top roll',[.389,.109,.213],[0,1.428,.305],mat.tan);
  box(body,'Pack bottom pocket',[.376,.155,.115],[0,.923,.384],mat.tan);
  for(const side of [-1,1]){
    box(body,`Pack side pocket ${side}`,[.098,.239,.172],[side*.23,1.117,.319],mat.tan);
    box(body,`Pack compression strap ${side}`,[.035,.508,.223],[side*.13,1.17,.309],mat.webbing);
    box(body,`Pack buckle ${side}`,[.048,.045,.012],[side*.13,1.282,.428],mat.metal);
  }
  box(body,'Pack rear MOLLE strip',[.31,.031,.01],[0,1.305,.416],mat.webbing);
  box(body,'Pack rear MOLLE strip lower',[.31,.031,.01],[0,1.18,.416],mat.webbing);
  box(body,'Pack antenna base',[.036,.047,.038],[.122,1.471,.311],mat.metal);
  box(body,'Short radio antenna',[.018,.193,.018],[.122,1.582,.311],mat.webbing);

  // Arms remain on named shoulder pivots for Godot aim and strike animation.
  for(const side of [-1,1]){
    const label=side<0?'L':'R';
    const arm=pivot(body,`Shoulder${label}`,[side*.37,1.42,0]);
    box(arm,`Upper sleeve ${label}`,[.229,.28,.255],[0,-.142,0],mat.cloth);
    box(arm,`Shoulder armor ${label}`,[.285,.139,.296],[side*.008,-.048,0],mat.armor);
    box(arm,`Shoulder armor edge ${label}`,[.288,.019,.3],[side*.008,.024,0],mat.armorEdge);
    box(arm,`Elbow fabric ${label}`,[.221,.066,.243],[0,-.285,0],mat.clothShade);
    box(arm,`Forearm sleeve ${label}`,[.198,.22,.231],[0,-.401,0],mat.cloth);
    box(arm,`Forearm guard ${label}`,[.21,.208,.054],[0,-.392,-.13],mat.armor);
    box(arm,`Forearm guard edge ${label}`,[.208,.024,.058],[0,-.305,-.13],mat.armorEdge);
    box(arm,`Wrist cuff ${label}`,[.197,.066,.223],[0,-.537,0],mat.webbing);
    box(arm,`Glove palm ${label}`,[.178,.115,.198],[0,-.625,-.01],mat.rubber);
    box(arm,`Glove knuckles ${label}`,[.182,.032,.206],[0,-.602,-.027],mat.armor);
    for(let i=0;i<3;i++)box(arm,`Glove finger ridge ${label}-${i}`,[.043,.025,.017],[-.054+i*.054,-.678,-.096],mat.armorEdge);
    box(arm,`Arm patch ${label}`,[.008,.069,.094],[side*.119,-.163,-.035],mat.tanDark);
    box(arm,`Arm patch line ${label}`,[.009,.014,.079],[side*.124,-.158,-.035],mat.tan);
    if(side===1){
      const mount=pivot(arm,'WeaponMount',[0,-.603,-.127]);
      mount.userData.purpose='Attach existing Godot gun here';
    }
  }
  box(body,'Shoulder telegraph lamp housing',[.117,.082,.09],[-.36,1.588,.016],mat.webbing);
  box(body,'TelegraphLamp',[.077,.052,.007],[-.36,1.588,-.034],mat.lamp);

  // Head pivot is at the neck; helmet, visor and covered face face toward -Z.
  const head=pivot(body,'Head',[0,1.52,0]);
  box(head,'Neck gaiter',[.294,.079,.274],[0,.035,0],mat.webbing);
  box(head,'Head base',[.332,.335,.329],[0,.22,0],mat.skin);
  box(head,'Face covering',[.333,.145,.068],[0,.17,-.163],mat.clothShade);
  box(head,'Nose cover seam',[.263,.023,.006],[0,.202,-.202],mat.tanDark);
  box(head,'Helmet shell',[.404,.164,.38],[0,.348,.008],mat.armor);
  box(head,'Helmet crown',[.36,.064,.334],[0,.415,.005],mat.armorEdge);
  box(head,'Helmet front brow',[.434,.057,.132],[0,.322,-.174],mat.armor);
  box(head,'Helmet rear rim',[.404,.065,.061],[0,.311,.195],mat.armor);
  box(head,'Front visor',[.316,.071,.026],[0,.292,-.214],mat.visor);
  box(head,'Visor lower lip',[.348,.016,.034],[0,.245,-.215],mat.metal);
  for(const side of [-1,1]){
    box(head,`Helmet side rail ${side}`,[.033,.057,.254],[side*.215,.34,.005],mat.webbing);
    box(head,`Ear cover ${side}`,[.066,.15,.168],[side*.185,.208,.035],mat.armor);
    box(head,`Goggle strap ${side}`,[.009,.036,.17],[side*.208,.289,.011],mat.rubber);
    box(head,`Chin strap ${side}`,[.022,.178,.025],[side*.159,.104,-.074],mat.tanDark, [0,0,side*.12]);
    box(head,`Helmet scuff ${side}`,[.061,.007,.08],[side*.124,.413,-.052],mat.tanDark);
  }
  box(head,'Helmet front mount',[.078,.066,.027],[0,.398,-.207],mat.webbing);
  box(head,'Helmet NVG rail',[.098,.013,.037],[0,.434,-.213],mat.metal);

  root.userData.meshCount=meshes;
  root.userData.description='MW2-era voxel tactical grunt, Godot pivot hierarchy';
  return root;
}
