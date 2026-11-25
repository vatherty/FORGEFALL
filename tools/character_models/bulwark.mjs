/** Heavy shield defender. Feet at y=0; front is -Z. */
export function buildBulwark(THREE) {
  const root = new THREE.Group(); root.name = 'Bulwark';
  const body = new THREE.Group(); body.name = 'BodyRoot'; root.add(body);
  const m = {
    cloth: new THREE.MeshStandardMaterial({color:0x565d52,roughness:.98}),
    dark: new THREE.MeshStandardMaterial({color:0x202a2a,roughness:.92}),
    armor: new THREE.MeshStandardMaterial({color:0xb3bbb0,roughness:.72,metalness:.19}),
    edge: new THREE.MeshStandardMaterial({color:0xd3d9cb,roughness:.68,metalness:.25}),
    plate: new THREE.MeshStandardMaterial({color:0x7b897e,roughness:.72,metalness:.28}),
    green: new THREE.MeshStandardMaterial({color:0x6d9c59,roughness:.55,metalness:.14,emissive:0x13240e,emissiveIntensity:.28}),
    glass: new THREE.MeshStandardMaterial({color:0x213a38,roughness:.29,metalness:.3}),
    rubber: new THREE.MeshStandardMaterial({color:0x171c1c,roughness:.97}),
    steel: new THREE.MeshStandardMaterial({color:0x495556,roughness:.51,metalness:.68}),
  };
  let meshes=0;
  function b(p,n,s,x,k,r){const o=new THREE.Mesh(new THREE.BoxGeometry(...s),m[k]);o.name=n;o.position.set(...x);if(r)o.rotation.set(...r);o.castShadow=true;o.receiveShadow=true;p.add(o);meshes++;return o}
  function pivot(p,n,x){const o=new THREE.Group();o.name=n;o.position.set(...x);p.add(o);return o}

  // Wide grounded legs and reinforced boots communicate the slower tank role.
  for(const side of [-1,1]) {
    const q=side<0?'L':'R', hip=pivot(body,`Hip${q}`,[side*.175,.77,0]);
    b(hip,`thigh ${q}`,[.275,.40,.295],[0,-.20,0],'cloth');
    b(hip,`outer armor ${q}`,[.073,.34,.31],[side*.14,-.20,-.004],'plate');
    b(hip,`thigh front ${q}`,[.244,.18,.053],[0,-.17,-.168],'armor');
    b(hip,`knee hinge ${q}`,[.238,.087,.255],[0,-.414,0],'dark');
    b(hip,`knee plate ${q}`,[.256,.158,.065],[0,-.449,-.166],'edge');
    b(hip,`knee green slash ${q}`,[.194,.016,.069],[0,-.464,-.203],'green');
    b(hip,`shin ${q}`,[.228,.238,.26],[0,-.579,.016],'cloth');
    b(hip,`shin guard ${q}`,[.214,.236,.06],[0,-.58,-.142],'armor');
    b(hip,`boot ankle ${q}`,[.27,.125,.27],[0,-.688,.012],'rubber');
    b(hip,`boot toe ${q}`,[.277,.075,.389],[0,-.729,-.074],'rubber');
    b(hip,`boot steel toe ${q}`,[.28,.033,.148],[0,-.747,-.193],'steel');
  }
  b(body,'pelvis',[.57,.19,.36],[0,.79,0],'dark');
  b(body,'belt',[.62,.095,.384],[0,.866,0],'steel');
  b(body,'torso base',[.69,.58,.39],[0,1.196,0],'cloth');
  b(body,'rear armor',[.66,.48,.10],[0,1.20,.243],'plate');
  b(body,'front armor foundation',[.64,.53,.13],[0,1.19,-.242],'steel');
  b(body,'upper ballistic plate',[.624,.274,.10],[0,1.333,-.31],'armor');
  b(body,'lower ballistic plate',[.63,.176,.103],[0,1.095,-.31],'plate');
  b(body,'plate center ridge',[.084,.39,.02],[0,1.236,-.371],'edge');
  b(body,'chest green status',[.095,.044,.027],[0,1.404,-.378],'green');
  b(body,'neck collar',[.52,.125,.43],[0,1.52,-.007],'dark');
  for(const side of [-1,1]) {
    b(body,`rib slab ${side}`,[.128,.37,.41],[side*.34,1.166,0],'armor');
    b(body,`rib edge ${side}`,[.032,.353,.43],[side*.405,1.166,0],'edge');
    b(body,`harness ${side}`,[.083,.42,.025],[side*.24,1.21,-.389],'dark');
    b(body,`waist pouch ${side}`,[.167,.139,.131],[side*.223,.821,-.227],'plate');
    b(body,`waist pouch lid ${side}`,[.177,.031,.14],[side*.223,.895,-.23],'edge');
  }
  b(body,'power pack main',[.44,.42,.25],[0,1.203,.342],'steel');
  b(body,'power pack center',[.21,.34,.032],[0,1.207,.481],'plate');
  for(const side of [-1,1]) {
    b(body,`power cell ${side}`,[.088,.285,.04],[side*.142,1.21,.492],'dark');
    b(body,`power indicator ${side}`,[.063,.036,.045],[side*.142,1.284,.517],'green');
  }

  for(const side of [-1,1]) {
    const q=side<0?'L':'R', arm=pivot(body,`Shoulder${q}`,[side*.475,1.48,0]);
    b(arm,`upper arm ${q}`,[.287,.315,.30],[0,-.159,0],'cloth');
    b(arm,`deltoid slab ${q}`,[.356,.211,.34],[side*.018,-.045,-.006],'armor');
    b(arm,`deltoid upper lip ${q}`,[.358,.037,.342],[side*.018,.049,-.006],'edge');
    b(arm,`elbow hinge ${q}`,[.259,.071,.27],[0,-.341,0],'dark');
    b(arm,`forearm ${q}`,[.252,.259,.27],[0,-.474,0],'cloth');
    b(arm,`forearm plate ${q}`,[.275,.24,.085],[0,-.471,-.161],'plate');
    b(arm,`gauntlet ${q}`,[.266,.13,.275],[0,-.633,0],'rubber');
    b(arm,`knuckle plate ${q}`,[.269,.044,.27],[0,-.612,-.021],'armor');
    b(arm,`shoulder green marking ${q}`,[.13,.017,.26],[side*.07,.065,0],'green');
    if(side===1) pivot(arm,'WeaponMount',[0,-.626,-.15]);
    if(side===-1) {
      // Shield belongs to the left arm pivot; it follows defensive poses.
      const shield=pivot(arm,'Shield',[-.045,-.403,-.314]);
      b(shield,'shield backing',[.65,1.13,.085],[0,.13,0],'steel');
      b(shield,'shield armor face',[.604,1.052,.058],[0,.13,-.073],'armor');
      b(shield,'shield lower apron',[.49,.118,.068],[0,-.424,-.084],'plate');
      b(shield,'shield upper brow',[.65,.089,.10],[0,.681,-.069],'edge');
      b(shield,'shield vertical spine',[.071,.97,.025],[0,.112,-.116],'edge');
      for(const s of [-1,1]) {
        b(shield,`shield bevel ${s}`,[.052,.95,.09],[s*.295,.13,-.095],'plate');
        b(shield,`shield grip rail ${s}`,[.031,.68,.035],[s*.24,.15,.064],'dark');
        b(shield,`shield green slash ${s}`,[.033,.36,.025],[s*.215,.39,-.119],'green');
      }
      b(shield,'viewport armored border',[.33,.128,.024],[0,.391,-.116],'dark');
      b(shield,'viewport glass',[.278,.067,.027],[0,.393,-.132],'glass');
    }
  }

  const head=pivot(body,'Head',[0,1.61,0]);
  b(head,'neck seal',[.31,.12,.31],[0,.034,0],'rubber');
  b(head,'head shell',[.37,.32,.36],[0,.227,0],'dark');
  b(head,'helmet low skirt',[.47,.19,.43],[0,.317,.015],'plate');
  b(head,'helmet crown',[.42,.097,.37],[0,.444,.015],'armor');
  b(head,'helmet top ridge',[.11,.028,.35],[0,.50,.015],'edge');
  b(head,'helmet face plate',[.40,.205,.074],[0,.218,-.203],'armor');
  b(head,'helmet visor slot',[.32,.065,.018],[0,.303,-.246],'glass');
  b(head,'helmet respirator',[.19,.112,.082],[0,.16,-.267],'steel');
  b(head,'respirator green vent',[.13,.022,.008],[0,.149,-.312],'green');
  for(const side of [-1,1]) {
    b(head,`helmet cheek ${side}`,[.089,.178,.202],[side*.196,.206,-.13],'edge');
    b(head,`ear cover ${side}`,[.076,.175,.2],[side*.231,.267,.048],'steel');
  }
  root.userData.meshCount=meshes;
  root.userData.description='Voxel heavy shield defender; MW2-era pale tactical armor, arm-pivot ballistic shield';
  return root;
}
