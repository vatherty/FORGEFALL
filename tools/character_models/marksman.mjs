/** Hooded precision marksman, MW2-era voxel tactics, forward -Z. */
export function buildMarksman(THREE) {
  const root=new THREE.Group();root.name='Marksman';
  const body=new THREE.Group();body.name='BodyRoot';root.add(body);
  const m={
    cloth:new THREE.MeshStandardMaterial({color:0x424b43,roughness:.98}),
    clothDeep:new THREE.MeshStandardMaterial({color:0x303a35,roughness:.99}),
    clothLight:new THREE.MeshStandardMaterial({color:0x5c6858,roughness:.98}),
    armor:new THREE.MeshStandardMaterial({color:0x38413e,roughness:.88,metalness:.15}),
    edge:new THREE.MeshStandardMaterial({color:0x66716a,roughness:.8,metalness:.21}),
    web:new THREE.MeshStandardMaterial({color:0x242d2a,roughness:.96}),
    olive:new THREE.MeshStandardMaterial({color:0x70765e,roughness:.93}),
    tan:new THREE.MeshStandardMaterial({color:0x93866b,roughness:.95}),
    rubber:new THREE.MeshStandardMaterial({color:0x1d2423,roughness:.99}),
    skin:new THREE.MeshStandardMaterial({color:0x8b705f,roughness:.94}),
    lens:new THREE.MeshStandardMaterial({color:0x274549,roughness:.25,metalness:.48}),
    metal:new THREE.MeshStandardMaterial({color:0x67736f,roughness:.61,metalness:.46}),
  };
  let meshes=0;
  function b(parent,name,size,pos,mat,rot){const o=new THREE.Mesh(new THREE.BoxGeometry(...size),mat);o.name=name;o.position.set(...pos);if(rot)o.rotation.set(...rot);o.castShadow=true;o.receiveShadow=true;parent.add(o);meshes++;return o}
  function p(parent,name,pos){const o=new THREE.Group();o.name=name;o.position.set(...pos);parent.add(o);return o}

  // Slender dark legs with kneeling pads and compact boots.
  for(const side of [-1,1]){
    const label=side<0?'L':'R',hip=p(body,`Hip${label}`,[side*.139,.75,0]);
    b(hip,`Upper trouser ${label}`,[.222,.39,.251],[0,-.202,.012],m.cloth);
    b(hip,`Knee fold ${label}`,[.215,.055,.253],[0,-.396,.012],m.clothLight);
    b(hip,`Kneeling pad ${label}`,[.19,.142,.048],[0,-.452,-.125],m.armor);
    b(hip,`Knee strap ${label}`,[.227,.018,.264],[0,-.477,.012],m.web);
    b(hip,`Lower trouser ${label}`,[.202,.25,.221],[0,-.574,.024],m.clothDeep);
    b(hip,`Cuff ${label}`,[.205,.062,.232],[0,-.671,.024],m.web);
    b(hip,`Field boot ${label}`,[.229,.114,.312],[0,-.686,-.048],m.rubber);
    b(hip,`Boot front ${label}`,[.232,.041,.106],[0,-.725,-.162],m.armor);
    b(hip,`Boot sole ${label}`,[.233,.02,.325],[0,-.74,-.059],m.web);
    b(hip,`Thigh utility slot ${label}`,[.013,.159,.12],[side*.118,-.213,.013],m.web);
  }

  // Thin plate carrier under a split camouflage cloak, with sniper gear.
  b(body,'Pelvis',[.468,.153,.263],[0,.81,.005],m.clothDeep);
  b(body,'Torso',[.496,.652,.306],[0,1.122,.01],m.cloth);
  b(body,'Vest front',[.44,.332,.078],[0,1.22,-.177],m.armor);
  b(body,'Vest back',[.445,.338,.061],[0,1.222,.184],m.armor);
  b(body,'High collar',[.371,.091,.315],[0,1.463,0],m.web);
  b(body,'Carrier upper strap',[.403,.025,.086],[0,1.394,-.181],m.edge);
  for(const side of [-1,1]){
    b(body,`Front rig strap ${side}`,[.052,.375,.019],[side*.177,1.242,-.228],m.web);
    b(body,`Utility pouch ${side}`,[.146,.166,.067],[side*.135,1.085,-.239],m.olive);
    b(body,`Pouch flap ${side}`,[.154,.027,.075],[side*.135,1.167,-.245],m.web);
    b(body,`Upper cloak drape ${side}`,[.156,.354,.342],[side*.276,1.308,.053],m.clothDeep,[0,0,side*.12]);
    b(body,`Cloak ragged hem ${side}`,[.118,.335,.023],[side*.324,.986,-.124],m.clothLight,[0,0,side*.11]);
    b(body,`Belt side bag ${side}`,[.112,.127,.102],[side*.205,.834,.115],m.olive);
  }
  b(body,'Load belt',[.515,.081,.341],[0,.853,.009],m.web);
  b(body,'Belt buckle',[.058,.052,.024],[0,.858,-.178],m.metal);
  b(body,'Cloak upper back',[.528,.414,.045],[0,1.32,.246],m.clothDeep);
  b(body,'Cloak lower back left',[.212,.376,.042],[-.125,.986,.254],m.cloth);
  b(body,'Cloak lower back right',[.202,.305,.042],[.126,1.008,.254],m.clothLight);
  b(body,'Rifle ammunition bandolier',[.078,.548,.025],[-.053,1.191,-.231],m.tan,[0,0,-.32]);
  for(let i=0;i<5;i++)b(body,`Bandolier cartridge ${i}`,[.035,.059,.012],[-.106+i*.027,1.33-i*.065,-.25],m.metal,[0,0,-.32]);
  b(body,'Narrow field pack',[.347,.423,.164],[0,1.172,.295],m.olive);
  b(body,'Pack lower pocket',[.302,.139,.073],[0,.973,.391],m.clothDeep);
  b(body,'Pack rain flap',[.36,.079,.173],[0,1.403,.292],m.web);
  for(const side of [-1,1])b(body,`Pack strap ${side}`,[.025,.43,.17],[side*.127,1.165,.308],m.web);
  b(body,'Spotting scope case',[.071,.342,.074],[.23,1.17,.31],m.rubber,[0,0,-.24]);
  b(body,'Spotting scope cap',[.079,.024,.079],[.269,1.315,.31],m.metal);

  // Controlled, slim arm shapes and gloves.
  for(const side of [-1,1]){
    const label=side<0?'L':'R',arm=p(body,`Shoulder${label}`,[side*.349,1.424,0]);
    b(arm,`Upper sleeve ${label}`,[.218,.289,.236],[0,-.157,0],m.cloth);
    b(arm,`Shoulder cowl ${label}`,[.257,.119,.287],[0,-.055,.011],m.clothDeep);
    b(arm,`Elbow wrap ${label}`,[.218,.072,.244],[0,-.294,0],m.web);
    b(arm,`Forearm sleeve ${label}`,[.19,.226,.211],[0,-.419,0],m.clothDeep);
    b(arm,`Forearm reinforcement ${label}`,[.194,.172,.04],[0,-.422,-.11],m.armor);
    b(arm,`Wrist wrap ${label}`,[.2,.059,.22],[0,-.545,0],m.olive);
    b(arm,`Glove ${label}`,[.183,.119,.195],[0,-.627,-.011],m.rubber);
    b(arm,`Glove hard knuckle ${label}`,[.186,.026,.199],[0,-.601,-.025],m.armor);
    if(side===1)p(arm,'WeaponMount',[0,-.616,-.122]);
  }

  // Hood frames a masked face; asymmetrical rangefinder reads precision role.
  const head=p(body,'Head',[0,1.52,0]);
  b(head,'Neck wrap',[.316,.111,.317],[0,.055,.012],m.web);
  b(head,'Face',[.315,.323,.305],[0,.203,0],m.skin);
  b(head,'Lower face mask',[.334,.146,.059],[0,.142,-.159],m.clothDeep);
  b(head,'Hood upper',[.424,.193,.391],[0,.378,.031],m.clothDeep);
  b(head,'Hood rear drape',[.429,.262,.068],[0,.205,.199],m.cloth);
  for(const side of [-1,1]){
    b(head,`Hood face edge ${side}`,[.076,.244,.057],[side*.192,.24,-.168],m.cloth);
    b(head,`Hood rag strip ${side}`,[.052,.12,.316],[side*.175,.413,.019],m.clothLight,[0,0,side*.09]);
    b(head,`Camo fringe ${side}`,[.054,.102,.057],[side*.161,.493,-.12],m.olive);
  }
  b(head,'Hood brow',[.358,.06,.103],[0,.341,-.2],m.cloth);
  b(head,'Eye shadow',[.274,.053,.018],[0,.271,-.199],m.web);
  b(head,'Optic mount',[.1,.102,.092],[.124,.284,-.182],m.armor);
  b(head,'Optic eyepiece',[.075,.062,.065],[.124,.284,-.238],m.rubber);
  b(head,'Optic front lens',[.052,.046,.006],[.124,.284,-.274],m.lens);
  b(head,'Optic upper button',[.031,.015,.035],[.123,.344,-.202],m.metal);
  b(head,'Left eye slit',[.086,.029,.006],[-.085,.275,-.206],m.lens);
  b(head,'Camo front fringe',[.075,.113,.037],[-.02,.445,-.217],m.olive,[0,0,.18]);

  root.userData.meshCount=meshes;
  root.userData.description='Hooded voxel precision marksman';
  return root;
}
