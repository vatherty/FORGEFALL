/** Fast militia rusher: lean MW2-era voxel silhouette, forward -Z. */
export function buildRusher(THREE) {
  const root=new THREE.Group();root.name='Rusher';
  const body=new THREE.Group();body.name='BodyRoot';root.add(body);
  const m={
    cloth:new THREE.MeshStandardMaterial({color:0x737d70,roughness:.98}),
    clothDark:new THREE.MeshStandardMaterial({color:0x4c5850,roughness:.99}),
    clothLight:new THREE.MeshStandardMaterial({color:0x98a08b,roughness:.97}),
    armor:new THREE.MeshStandardMaterial({color:0x4a524f,roughness:.84,metalness:.17}),
    edge:new THREE.MeshStandardMaterial({color:0x747c76,roughness:.78,metalness:.22}),
    tan:new THREE.MeshStandardMaterial({color:0x96876b,roughness:.94}),
    web:new THREE.MeshStandardMaterial({color:0x383e3b,roughness:.96}),
    rubber:new THREE.MeshStandardMaterial({color:0x252b29,roughness:.99}),
    skin:new THREE.MeshStandardMaterial({color:0x987965,roughness:.93}),
    lens:new THREE.MeshStandardMaterial({color:0x40555a,roughness:.28,metalness:.37}),
    metal:new THREE.MeshStandardMaterial({color:0x596660,roughness:.62,metalness:.4}),
  };
  let meshes=0;
  function b(parent,name,size,pos,mat,rot){const o=new THREE.Mesh(new THREE.BoxGeometry(...size),mat);o.name=name;o.position.set(...pos);if(rot)o.rotation.set(...rot);o.castShadow=true;o.receiveShadow=true;parent.add(o);meshes++;return o}
  function p(parent,name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);parent.add(o);return o}

  // Slim trousers, long stride and lightweight sneakers.
  for(const side of [-1,1]){
    const label=side<0?'L':'R',hip=p(body,`Hip${label}`,[side*.128,.76,0]);
    b(hip,`Trouser thigh ${label}`,[.203,.373,.234],[0,-.19,0],m.cloth);
    b(hip,`Trouser taper ${label}`,[.187,.289,.215],[0,-.521,.017],m.clothDark);
    b(hip,`Knee wrap ${label}`,[.203,.075,.231],[0,-.392,.01],m.web);
    b(hip,`Knee skid ${label}`,[.16,.087,.038],[0,-.399,-.113],m.armor);
    b(hip,`Cargo side pocket ${label}`,[.016,.104,.115],[side*.108,-.21,.035],m.clothDark);
    b(hip,`Pocket flap ${label}`,[.021,.021,.119],[side*.119,-.153,.035],m.tan);
    b(hip,`Ankle cuff ${label}`,[.19,.058,.233],[0,-.664,.018],m.web);
    b(hip,`Light boot ${label}`,[.21,.105,.305],[0,-.7,-.055],m.rubber);
    b(hip,`Toe rubber ${label}`,[.215,.041,.112],[0,-.726,-.162],m.armor);
    b(hip,`Sole ${label}`,[.219,.02,.323],[0,-.75,-.058],m.web);
    for(let i=0;i<2;i++)b(hip,`Boot lace ${label}-${i}`,[.114,.005,.015],[0,-.684-i*.019,-.113],m.tan);
  }

  // Thin torso and crossing harness. The light rig reads fast at distance.
  b(body,'Pelvis',[.43,.145,.248],[0,.817,.007],m.clothDark);
  b(body,'Torso fatigues',[.452,.663,.283],[0,1.148,.01],m.cloth);
  b(body,'Raised collar',[.342,.105,.286],[0,1.462,.014],m.clothDark);
  b(body,'Short front vest',[.421,.263,.058],[0,1.264,-.163],m.armor);
  b(body,'Rear vest',[.404,.264,.049],[0,1.262,.17],m.armor);
  for(const side of [-1,1]){
    b(body,`Crossed chest strap ${side}`,[.046,.45,.022],[side*.107,1.208,-.203],m.web,[0,0,side*.27]);
    b(body,`Harness shoulder ${side}`,[.061,.033,.336],[side*.131,1.47,0],m.web);
    b(body,`Light ammo pouch ${side}`,[.114,.126,.063],[side*.119,1.083,-.212],m.tan);
    b(body,`Ammo pouch flap ${side}`,[.12,.022,.069],[side*.119,1.146,-.216],m.web);
    b(body,`Belt hip pouch ${side}`,[.104,.116,.077],[side*.205,.83,-.11],m.tan);
  }
  b(body,'Narrow belt',[.473,.059,.287],[0,.866,.011],m.web);
  b(body,'Belt buckle',[.053,.043,.023],[0,.867,-.149],m.metal);
  b(body,'Small hydration pack',[.289,.345,.117],[0,1.205,.217],m.tan);
  b(body,'Pack pocket',[.234,.128,.053],[0,1.139,.304],m.clothDark);
  b(body,'Pack upper roll',[.292,.06,.127],[0,1.403,.216],m.web);
  for(const side of [-1,1])b(body,`Pack strap ${side}`,[.03,.369,.13],[side*.101,1.2,.245],m.web);
  b(body,'Hydration hose',[.023,.455,.022],[.155,1.308,-.016],m.rubber,[0,0,-.33]);

  // Free shoulders, cloth sleeves and fingerless gloves.
  for(const side of [-1,1]){
    const label=side<0?'L':'R',arm=p(body,`Shoulder${label}`,[side*.319,1.43,0]);
    b(arm,`Sleeve upper ${label}`,[.204,.277,.231],[0,-.149,0],m.cloth);
    b(arm,`Sleeve top patch ${label}`,[.216,.102,.241],[0,-.057,0],m.clothDark);
    b(arm,`Elbow ${label}`,[.195,.067,.223],[0,-.296,0],m.web);
    b(arm,`Forearm sleeve ${label}`,[.172,.204,.207],[0,-.404,0],m.cloth);
    b(arm,`Wrist wrap ${label}`,[.185,.062,.217],[0,-.529,0],m.tan);
    b(arm,`Glove palm ${label}`,[.16,.084,.178],[0,-.599,-.01],m.rubber);
    b(arm,`Exposed fingertips ${label}`,[.146,.042,.17],[0,-.661,-.01],m.skin);
    b(arm,`Glove knuckles ${label}`,[.166,.024,.17],[0,-.593,-.037],m.armor);
    b(arm,`Upper arm patch ${label}`,[.007,.083,.082],[side*.108,-.177,-.016],m.tan);
    if(side===1)p(arm,'WeaponMount',[0,-.605,-.115]);
  }

  // Flat patrol cap, thick goggles and lower-face wrap.
  const head=p(body,'Head',[0,1.52,0]);
  b(head,'Neck wrap',[.278,.088,.279],[0,.033,.003],m.web);
  b(head,'Face',[.313,.327,.312],[0,.211,0],m.skin);
  b(head,'Lower face mask',[.328,.135,.055],[0,.137,-.16],m.clothDark);
  b(head,'Mask crease',[.252,.015,.006],[0,.142,-.192],m.tan);
  b(head,'Patrol cap crown',[.378,.123,.347],[0,.378,.006],m.clothDark);
  b(head,'Cap bill',[.349,.028,.136],[0,.326,-.221],m.clothDark);
  b(head,'Cap front badge',[.061,.032,.006],[0,.385,-.172],m.tan);
  b(head,'Goggle frame',[.36,.089,.041],[0,.271,-.193],m.rubber);
  for(const side of [-1,1]){
    b(head,`Goggle lens ${side}`,[.13,.057,.005],[side*.084,.277,-.218],m.lens);
    b(head,`Goggle strap ${side}`,[.015,.041,.15],[side*.184,.269,-.027],m.web);
    b(head,`Ear guard ${side}`,[.043,.108,.09],[side*.171,.19,.005],m.clothDark);
  }

  root.userData.meshCount=meshes;
  root.userData.description='Lean voxel militia rusher';
  return root;
}
