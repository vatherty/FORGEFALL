/** SP-1 Ember: worn, field-built starter sidearm; forward -Z. */
export function buildEmber(THREE) {
  const g=new THREE.Group();g.name='VM_ember';
  const m={
    steel:new THREE.MeshStandardMaterial({color:0x454847,roughness:.74,metalness:.43}),
    edge:new THREE.MeshStandardMaterial({color:0x777873,roughness:.65,metalness:.51}),
    dark:new THREE.MeshStandardMaterial({color:0x222625,roughness:.86,metalness:.26}),
    bore:new THREE.MeshStandardMaterial({color:0x101415,roughness:.77,metalness:.32}),
    worn:new THREE.MeshStandardMaterial({color:0x65574a,roughness:.86,metalness:.19}),
    rust:new THREE.MeshStandardMaterial({color:0x86543b,roughness:.96,metalness:.07}),
    wrap:new THREE.MeshStandardMaterial({color:0x897a61,roughness:.97,metalness:.02}),
    wrapDark:new THREE.MeshStandardMaterial({color:0x5d5444,roughness:.98,metalness:.01}),
    brass:new THREE.MeshStandardMaterial({color:0x9a7950,roughness:.59,metalness:.58}),
    ember:new THREE.MeshStandardMaterial({color:0xd87330,roughness:.39,emissive:0x642209,emissiveIntensity:.7}),
  };
  let meshes=0;
  function b(name,size,pos,material,rot){const o=new THREE.Mesh(new THREE.BoxGeometry(...size),material);o.name=name;o.position.set(...pos);if(rot)o.rotation.set(...rot);o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function c(name,r,len,pos,material,sides=8,rot=[Math.PI/2,0,0]){const o=new THREE.Mesh(new THREE.CylinderGeometry(r,r,len,sides),material);o.name=name;o.position.set(...pos);o.rotation.set(...rot);o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function profile(name,points,width,x,material){const s=new THREE.Shape();s.moveTo(points[0][0],points[0][1]);for(let i=1;i<points.length;i++)s.lineTo(points[i][0],points[i][1]);s.closePath();const geo=new THREE.ExtrudeGeometry(s,{depth:width,bevelEnabled:false});geo.rotateY(-Math.PI/2);geo.translate(x+width/2,0,0);const o=new THREE.Mesh(geo,material);o.name=name;o.castShadow=true;o.receiveShadow=true;g.add(o);meshes++;return o}
  function anchor(name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);g.add(o)}

  // Short slab-sided hand-fitted slide, visibly patched rather than factory cut.
  profile('Mismatched worn slide',[
    [-.228,.041],[-.215,.056],[-.051,.056],[-.026,.040],[-.026,-.001],
    [-.044,-.016],[-.217,-.016],[-.229,.001]
  ],.055,0,m.steel);
  b('Slide top flat',[.052,.006,.173],[0,.059,-.126],m.edge);
  b('Slide replacement front cap',[.059,.055,.027],[0,.021,-.217],m.worn);
  b('Slide rear reinforcement',[.058,.058,.025],[0,.020,-.034],m.dark);
  for(const side of [-1,1]){
    b(`Slide scuffed line ${side}`,[.003,.005,.133],[side*.029,.033,-.133],m.edge);
    b(`Patch plate ${side}`,[.004,.028,.054],[side*.03,.011,-.13],m.worn);
    for(let i=0;i<4;i++)b(`Rear cocking notch ${side}-${i}`,[.003,.034,.006],[side*.032,.022,-.071+i*.010],m.bore);
    for(let i=0;i<2;i++)b(`Patch rivet ${side}-${i}`,[.006,.007,.007],[side*.034,.015,-.151+i*.04],m.brass);
  }
  b('Ejection port cutout',[.031,.003,.056],[.011,.062,-.109],m.bore);
  b('Exposed chamber',[.023,.002,.040],[.011,.064,-.11],m.brass);
  b('Slide extractor',[.006,.009,.045],[.032,.043,-.074],m.dark);
  c('Short barrel',.015,.055,[0,.013,-.208],m.dark);
  c('Muzzle bushing',.022,.013,[0,.013,-.242],m.edge);
  c('Dark bore',.010,.004,[0,.013,-.251],m.bore);
  c('Recoil rod',.007,.022,[0,-.012,-.233],m.bore);

  // Exposed-looking low frame and simple trigger, preserving compact P9 scale.
  profile('Lower cast frame',[
    [-.214,-.011],[-.043,-.012],[.016,-.044],[.029,-.060],[-.012,-.067],
    [-.079,-.048],[-.159,-.052],[-.221,-.041]
  ],.051,0,m.dark);
  b('Underbarrel seam',[.054,.009,.159],[0,-.03,-.132],m.worn);
  b('Field welded lug',[.058,.028,.041],[0,-.045,-.174],m.rust);
  b('Dust cover block',[.048,.016,.062],[0,-.054,-.181],m.dark);
  for(const side of [-1,1]){
    b(`Frame screw ${side}`,[.005,.009,.009],[side*.028,-.025,-.047],m.brass);
    b(`Safety paddle ${side}`,[.007,.015,.027],[side*.032,-.007,-.034],m.worn);
  }
  b('Trigger pin',[.010,.016,.012],[0,-.061,-.071],m.edge);
  b('Trigger blade',[.008,.031,.008],[0,-.083,-.068],m.brass,[-.18,0,0]);
  b('Trigger guard front',[.008,.048,.008],[0,-.074,-.109],m.dark);
  b('Trigger guard bottom',[.008,.009,.073],[0,-.101,-.072],m.dark);
  b('Trigger guard rear',[.008,.029,.009],[0,-.086,-.035],m.dark);

  // Distinct long taped grip and crude magazine heel define the silhouette.
  profile('Grip metal tang',[[.005,-.049],[.055,-.063],[.078,-.171],[.026,-.184],[-.007,-.071]],.047,0,m.steel);
  b('Wrapped grip core',[.051,.116,.067],[0,-.113,.035],m.wrap,[-.18,0,0]);
  for(let i=0;i<5;i++)b(`Tape wrap ${i}`,[.054,.009,.068],[0,-.071-i*.021,.035],i%2?m.wrapDark:m.wrap,[-.18,0,0]);
  for(const side of [-1,1]){
    b(`Grip scale ${side}`,[.004,.078,.049],[side*.028,-.118,.039],m.wrapDark,[-.18,0,0]);
    b(`Grip scale rivet top ${side}`,[.005,.008,.008],[side*.031,-.09,.05],m.brass);
    b(`Grip scale rivet lower ${side}`,[.005,.008,.008],[side*.031,-.142,.05],m.brass);
  }
  b('Magazine toe',[.057,.017,.071],[0,-.183,.046],m.dark,[-.18,0,0]);
  b('Magazine uneven floorplate',[.062,.010,.077],[0,-.193,.046],m.rust,[-.18,0,0]);
  b('Rear beavertail',[.053,.015,.034],[0,-.054,.041],m.worn);
  b('Hammer base',[.029,.016,.029],[0,.01,.012],m.dark);
  b('Hammer spur',[.025,.012,.014],[0,.026,.024],m.edge);

  // Iron sights, deliberately simple and slightly asymmetrical.
  b('Front sight foot',[.026,.008,.019],[0,.064,-.204],m.dark);
  b('Front sight blade',[.009,.026,.009],[0,.081,-.204],m.worn);
  b('Front sight ember paint',[.008,.004,.003],[0,.093,-.208],m.ember);
  b('Rear sight foot',[.047,.011,.024],[0,.066,-.039],m.dark);
  for(const side of [-1,1])b(`Rear sight ear ${side}`,[.011,.017,.014],[side*.017,.079,-.039],m.edge);

  anchor('Sight',[0,.074,-.105]);
  anchor('Stock',[0,-.18,.046]);
  anchor('Grip',[0,-.113,.035]);
  anchor('Barrel',[0,.013,-.208]);
  anchor('Muzzle',[0,.013,-.255]);
  anchor('Eject',[.038,.045,-.11]);
  g.userData.meshCount=meshes;
  g.userData.description='SP-1 Ember worn field-built sidearm';
  return g;
}
