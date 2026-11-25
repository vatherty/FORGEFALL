/** Commanding heavy enemy in angular red armor. Feet y=0; forward -Z. */
export function buildWarlord(THREE) {
  const root=new THREE.Group(); root.name='Warlord';
  const body=new THREE.Group(); body.name='BodyRoot'; root.add(body);
  const m={
    black:new THREE.MeshStandardMaterial({color:0x202222,roughness:.91}),
    fabric:new THREE.MeshStandardMaterial({color:0x383333,roughness:.96}),
    red:new THREE.MeshStandardMaterial({color:0x793b38,roughness:.73,metalness:.24}),
    redLight:new THREE.MeshStandardMaterial({color:0xab5544,roughness:.68,metalness:.3}),
    oxide:new THREE.MeshStandardMaterial({color:0x482b2d,roughness:.81,metalness:.2}),
    gold:new THREE.MeshStandardMaterial({color:0xb39a64,roughness:.47,metalness:.58}),
    steel:new THREE.MeshStandardMaterial({color:0x565959,roughness:.5,metalness:.65}),
    rubber:new THREE.MeshStandardMaterial({color:0x141819,roughness:.98}),
    visor:new THREE.MeshStandardMaterial({color:0x222d2d,roughness:.27,metalness:.28}),
    light:new THREE.MeshStandardMaterial({color:0xe17d52,emissive:0x9b371b,emissiveIntensity:.45,roughness:.4}),
  };
  let meshes=0;
  function b(p,n,s,x,k,r){const o=new THREE.Mesh(new THREE.BoxGeometry(...s),m[k]);o.name=n;o.position.set(...x);if(r)o.rotation.set(...r);o.castShadow=true;o.receiveShadow=true;p.add(o);meshes++;return o}
  function pivot(p,n,x){const o=new THREE.Group();o.name=n;o.position.set(...x);p.add(o);return o}

  // Extended armored coat and high angular pauldrons define the boss outline.
  for(const side of [-1,1]){
    const q=side<0?'L':'R',hip=pivot(body,`Hip${q}`,[side*.16,.78,0]);
    b(hip,`armored trouser ${q}`,[.244,.42,.27],[0,-.21,0],'fabric');
    b(hip,`thigh plate ${q}`,[.225,.284,.063],[0,-.23,-.141],'red');
    b(hip,`outer thigh plate ${q}`,[.055,.322,.245],[side*.128,-.224,0],'oxide');
    b(hip,`thigh gold rank ${q}`,[.13,.014,.069],[0,-.156,-.185],'gold');
    b(hip,`knee joint ${q}`,[.227,.067,.252],[0,-.439,0],'black');
    b(hip,`knee armor ${q}`,[.241,.145,.058],[0,-.467,-.147],'redLight');
    b(hip,`shin ${q}`,[.213,.241,.238],[0,-.59,.019],'fabric');
    b(hip,`shin plate ${q}`,[.19,.208,.053],[0,-.58,-.128],'oxide');
    b(hip,`combat boot ${q}`,[.255,.15,.298],[0,-.69,-.001],'rubber');
    b(hip,`combat toe ${q}`,[.257,.073,.362],[0,-.739,-.07],'black');
    b(hip,`boot toe metal ${q}`,[.263,.025,.121],[0,-.748,-.193],'steel');
  }
  b(body,'pelvis',[.50,.19,.32],[0,.794,0],'black');
  b(body,'belt',[.56,.082,.358],[0,.861,0],'gold');
  b(body,'belt buckle',[.095,.054,.016],[0,.862,-.188],'red');
  b(body,'torso',[.576,.56,.33],[0,1.20,0],'fabric');
  b(body,'rear cuirass',[.56,.474,.101],[0,1.203,.212],'oxide');
  b(body,'front cuirass',[.555,.465,.102],[0,1.225,-.213],'red');
  b(body,'chest central armored keel',[.108,.421,.024],[0,1.237,-.277],'redLight');
  b(body,'chest gold top band',[.564,.019,.123],[0,1.463,-.21],'gold');
  b(body,'chest gold lower band',[.54,.022,.112],[0,1.027,-.211],'gold');
  b(body,'center commander insignia',[.105,.095,.02],[0,1.336,-.291],'gold');
  b(body,'insignia core',[.042,.04,.006],[0,1.337,-.305],'light');
  for(const side of [-1,1]){
    b(body,`side plate ${side}`,[.071,.35,.28],[side*.293,1.21,.008],'oxide');
    b(body,`chest webbing ${side}`,[.069,.34,.021],[side*.20,1.226,-.277],'black');
    b(body,`lower ammo pouch ${side}`,[.139,.105,.09],[side*.182,.84,-.21],'red');
    b(body,`ammo pouch clasp ${side}`,[.042,.02,.011],[side*.182,.84,-.265],'gold');
    b(body,`coat tail ${side}`,[.184,.477,.144],[side*.196,.663,.16],'oxide');
    b(body,`coat tail hem ${side}`,[.188,.04,.15],[side*.196,.439,.16],'redLight');
  }
  b(body,'central coat tail',[.139,.36,.139],[0,.721,.197],'black');
  b(body,'command pack',[.33,.37,.183],[0,1.232,.279],'black');
  b(body,'command pack vertical plate',[.17,.324,.042],[0,1.232,.392],'steel');
  b(body,'antenna',[.014,.274,.014],[.12,1.516,.316],'gold');
  b(body,'antenna light',[.027,.027,.027],[.12,1.667,.316],'light');
  b(body,'neck guard',[.40,.11,.335],[0,1.519,0],'black');

  for(const side of [-1,1]){
    const q=side<0?'L':'R',arm=pivot(body,`Shoulder${q}`,[side*.406,1.455,0]);
    b(arm,`upper sleeve ${q}`,[.249,.281,.269],[0,-.136,0],'fabric');
    b(arm,`large pauldron lower ${q}`,[.347,.189,.35],[side*.039,-.054,0],'red');
    b(arm,`pauldron raised wing ${q}`,[.357,.12,.374],[side*.071,.07,0],'oxide',[0,0,side*-.10]);
    b(arm,`pauldron gold rim ${q}`,[.354,.026,.37],[side*.071,.139,0],'gold',[0,0,side*-.10]);
    b(arm,`pauldron red inset ${q}`,[.095,.13,.019],[side*.129,-.011,-.191],'redLight');
    b(arm,`elbow joint ${q}`,[.221,.073,.236],[0,-.301,0],'black');
    b(arm,`forearm sleeve ${q}`,[.213,.227,.235],[0,-.414,0],'fabric');
    b(arm,`forearm vambrace ${q}`,[.222,.233,.064],[0,-.417,-.146],'red');
    b(arm,`vambrace gold slash ${q}`,[.171,.019,.067],[0,-.445,-.181],'gold');
    b(arm,`wrist ${q}`,[.21,.055,.235],[0,-.542,0],'black');
    b(arm,`glove ${q}`,[.189,.119,.22],[0,-.623,-.01],'rubber');
    b(arm,`knuckle guard ${q}`,[.193,.043,.226],[0,-.61,-.024],'steel');
    if(side===1)pivot(arm,'WeaponMount',[0,-.616,-.132]);
  }

  const head=pivot(body,'Head',[0,1.525,0]);
  b(head,'neck',[.27,.103,.264],[0,.064,0],'black');
  b(head,'helmet skull',[.353,.334,.34],[0,.256,0],'black');
  b(head,'helmet rear shell',[.38,.28,.093],[0,.28,.183],'red');
  b(head,'helmet brow',[.404,.098,.159],[0,.362,-.139],'red');
  b(head,'helmet crown',[.334,.093,.315],[0,.451,0],'oxide');
  b(head,'helmet front crest',[.114,.073,.275],[0,.51,-.015],'gold');
  b(head,'helmet face visor',[.307,.085,.034],[0,.298,-.2],'visor');
  b(head,'visor red edge',[.318,.015,.042],[0,.253,-.2],'redLight');
  b(head,'armored lower mask',[.326,.131,.078],[0,.171,-.18],'red');
  b(head,'mask vent',[.128,.045,.007],[0,.154,-.223],'steel');
  for(const side of [-1,1]){
    b(head,`helmet ear shell ${side}`,[.072,.183,.16],[side*.19,.275,.015],'oxide');
    b(head,`helmet gold cheek ${side}`,[.042,.19,.048],[side*.175,.196,-.136],'gold');
    b(head,`helmet upper rank mark ${side}`,[.07,.012,.108],[side*.124,.485,.003],'gold');
  }
  root.userData.meshCount=meshes;
  root.userData.description='MW2-era voxel commander boss with red/dark armor, gold rank trim and angular silhouette';
  return root;
}
