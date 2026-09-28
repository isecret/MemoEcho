import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { RectAreaLightUniformsLib } from 'three/addons/lights/RectAreaLightUniformsLib.js';

RectAreaLightUniformsLib.init();
const W = 1536, H = 1024;
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setSize(W, H);
// Render above delivery resolution to suppress thin-rim and specular aliasing.
renderer.setPixelRatio(3);
renderer.setClearColor(0x000000, 0);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1;
document.body.append(renderer.domElement);
const scene = new THREE.Scene();
const model = new THREE.Group(); model.name = 'MemoEcho_UFO';
const spec = { radius: 3.7, windowRadius: .135, orbitRadius: 2.96, windowCount: 12, elevation: -14.5, roll: 18 };
model.userData = { ...spec, description: 'Real circular openings and recessed glass in a curved underside; equal angular spacing.' };
const hull = new THREE.MeshStandardMaterial({ color: 0x303030, metalness: .65, roughness: .4 });
const belly = new THREE.MeshStandardMaterial({ color: 0x505050, metalness: .3, roughness: .42, side: THREE.DoubleSide });
const domeMaterial = new THREE.MeshPhysicalMaterial({ color: 0x777777, metalness: .75, roughness: .38, clearcoat: .14, clearcoatRoughness: .4 });
const gasket = new THREE.MeshStandardMaterial({ color: 0x080808, metalness: .25, roughness: .5 });
const bevel = new THREE.MeshStandardMaterial({ color: 0x515151, metalness: .7, roughness: .36 });
const glass = new THREE.MeshPhysicalMaterial({ color: 0x333333, metalness: .18, roughness: .26, clearcoat: 1, clearcoatRoughness: .12, side: THREE.DoubleSide });
const dark = new THREE.MeshStandardMaterial({ color: 0x060606, metalness: .45, roughness: .42, side: THREE.DoubleSide });
function mesh(geometry, material, name, parent = model) { const m = new THREE.Mesh(geometry, material); m.name = name; parent.add(m); return m; }
function lathe(points, material, name) {
  const profile = new THREE.SplineCurve(points.map(p => new THREE.Vector2(...p)));
  const samples = profile.getPoints(Math.max(64, points.length * 12));
  for (const point of samples) point.x = Math.min(spec.radius, Math.max(0, point.x));
  return mesh(new THREE.LatheGeometry(samples, 384), material, name);
}
function torus(radius, tube, material, name, y) { const m = mesh(new THREE.TorusGeometry(radius, tube, 24, 384), material, name); m.rotation.x = Math.PI / 2; m.position.y = y; return m; }
const undersideY = r => -.55 + .55 * (r / spec.radius) ** 2;
// Top shell and outer rolled edge are rotationally symmetric, not camera-facing artwork.
lathe([[0,.22],[1.75,.26],[2.05,.22],[2.65,.14],[3.3,.07],[3.62,.025],[3.7,0],[3.69,-.025]], hull, 'Upper_saucer_shell');
torus(3.688, .017, bevel, 'Rolled_outer_edge', -.01);
torus(3.49, .008, dark, 'Outer_hull_seam', undersideY(3.49) - .006);

// A real perforated annulus: triangulated shape with twelve circular holes, then warped into a bowl.
const outline = new THREE.Shape(); outline.absarc(0, 0, spec.radius - .01, 0, Math.PI * 2, false);
const centerHole = new THREE.Path(); centerHole.absarc(0, 0, 2.15, 0, Math.PI * 2, true); outline.holes.push(centerHole);
const centers = [];
for (let i = 0; i < spec.windowCount; i++) {
  const angle = (i + .5) * Math.PI * 2 / spec.windowCount;
  const x = Math.cos(angle) * spec.orbitRadius, z = Math.sin(angle) * spec.orbitRadius;
  const hole = new THREE.Path(); hole.absarc(x, z, spec.windowRadius, 0, Math.PI * 2, true); outline.holes.push(hole);
  centers.push({ x, z, angle });
}
// Uniform subdivision keeps shared edges conforming before curvature is applied.
// Adaptive triangle splits would leave visible T-junction cracks in a curved surface.
let vertices = Array.from(new THREE.ShapeGeometry(outline, 48).toNonIndexed().attributes.position.array);
for (let level=0;level<3;level++) {
  const next=[];
  for(let i=0;i<vertices.length;i+=9){
    const a=vertices.slice(i,i+3),b=vertices.slice(i+3,i+6),c=vertices.slice(i+6,i+9);
    const ab=a.map((v,j)=>(v+b[j])/2),bc=b.map((v,j)=>(v+c[j])/2),ca=c.map((v,j)=>(v+a[j])/2);
    next.push(...a,...ab,...ca,...ab,...b,...bc,...ca,...bc,...c,...ab,...bc,...ca);
  }
  vertices=next;
}
const normals=[];
for(let i=0;i<vertices.length;i+=3){
  const x=vertices[i],z=vertices[i+1];vertices[i+1]=undersideY(Math.hypot(x,z));vertices[i+2]=z;
  const normal=new THREE.Vector3(1.1*x/spec.radius**2,-1,1.1*z/spec.radius**2).normalize();normals.push(...normal.toArray());
}
const plate=new THREE.BufferGeometry();
plate.setAttribute('position',new THREE.Float32BufferAttribute(vertices,3));
plate.setAttribute('normal',new THREE.Float32BufferAttribute(normals,3));
const undersideMesh = mesh(plate, belly, 'Perforated_curved_underside');
// Each fitting uses the actual local surface normal. There are no hand-tuned screen-space offsets.
const windows = new THREE.Group(); windows.name = 'Twelve_radial_portholes'; model.add(windows);
for (let i = 0; i < centers.length; i++) {
  const { x, z, angle } = centers[i];
  const slope = 1.1 * spec.orbitRadius / spec.radius ** 2;
  const normal = new THREE.Vector3(Math.cos(angle) * slope, -1, Math.sin(angle) * slope).normalize();
  const fitting = new THREE.Group(); fitting.name = `Porthole_${String(i + 1).padStart(2,'0')}`;
  fitting.position.set(x, undersideY(spec.orbitRadius), z);
  fitting.quaternion.setFromUnitVectors(new THREE.Vector3(0,0,1), normal);
  fitting.userData = { angleDegrees: THREE.MathUtils.radToDeg(angle), orbitRadius: spec.orbitRadius, surfaceNormal: normal.toArray() };
  windows.add(fitting);
  const sleeve = mesh(new THREE.CylinderGeometry(spec.windowRadius, spec.windowRadius, .075, 48, 1, true), gasket, 'Recess_wall', fitting);
  sleeve.rotation.x = Math.PI / 2; sleeve.position.z = -.03;
  mesh(new THREE.TorusGeometry(spec.windowRadius + .006, .009, 24, 128), bevel, 'Flush_metal_lip', fitting);
  const pane = mesh(new THREE.CircleGeometry(spec.windowRadius - .012, 128), glass, 'Recessed_glass', fitting); pane.position.z = -.028;
  const backing = mesh(new THREE.CircleGeometry(spec.windowRadius - .009, 64), dark, 'Dark_cabin_interior', fitting); backing.position.z = -.065;
}
lathe([[1.14,-.5],[1.5,undersideY(1.5)],[1.85,undersideY(1.85)],[2.15,undersideY(2.15)]],dark,'Inner_emitter_recess');
// Central emitter has its own physical socket, which can occlude the far side naturally.
lathe([[1.15,-.48],[1.14,-.57],[1.09,-.61],[1.035,-.61]], dark, 'Emitter_socket');
torus(1.075,.026,bevel,'Emitter_bezel',-.595);
// A recessed luminous diffuser has a gentle edge falloff instead of a solid white cutout.
const diffuser = document.createElement('canvas'); diffuser.width = diffuser.height = 256;
const dc = diffuser.getContext('2d');
const falloff = dc.createRadialGradient(116,110,25,128,128,128);
falloff.addColorStop(0,'#ffffff'); falloff.addColorStop(.7,'#f6f6f6'); falloff.addColorStop(.93,'#e8e8e8'); falloff.addColorStop(1,'#c9c9c9');
dc.fillStyle=falloff;dc.fillRect(0,0,256,256);
const diffuserTexture=new THREE.CanvasTexture(diffuser);diffuserTexture.colorSpace=THREE.SRGBColorSpace;
const emitter = mesh(new THREE.CircleGeometry(1.055,256), new THREE.MeshBasicMaterial({map:diffuserTexture,color:0xffffff,side:THREE.DoubleSide,toneMapped:false}), 'Light_aperture');
emitter.rotation.x = Math.PI / 2; emitter.position.y = -.602;
const dome = mesh(new THREE.SphereGeometry(1,256,128,0,Math.PI*2,0,Math.PI/2), domeMaterial,'Satin_metal_dome');
dome.scale.set(1.92,2.18,1.92); dome.position.y=.24;
torus(1.91,.022,hull,'Dome_seal',.245);

// Environment cards produce a real curved highlight across the dome.
const environment = new THREE.Scene();
environment.add(new THREE.Mesh(new THREE.SphereGeometry(30,32,16),new THREE.MeshBasicMaterial({color:0x070707,side:THREE.BackSide})));
function card(x,y,z,w,h,intensity) { const m=new THREE.Mesh(new THREE.PlaneGeometry(w,h),new THREE.MeshBasicMaterial({color:new THREE.Color().setScalar(intensity),side:THREE.DoubleSide}));m.position.set(x,y,z);m.lookAt(0,0,0);environment.add(m); }
const reflectionArc=new THREE.Mesh(new THREE.RingGeometry(1.6,2.15,64,1,.3,2.3),new THREE.MeshBasicMaterial({color:new THREE.Color().setScalar(4),side:THREE.DoubleSide}));
reflectionArc.position.set(-6,6,-7);reflectionArc.lookAt(0,0,0);environment.add(reflectionArc);
card(6,2,-3,1,8,.4);card(0,-6,7,9,5,.9);
const pmrem=new THREE.PMREMGenerator(renderer);scene.environment=pmrem.fromScene(environment,.16).texture;scene.environmentIntensity=1.1;
scene.add(new THREE.AmbientLight(0xffffff,.07));
function area(x,y,z,w,h,power) {const l=new THREE.RectAreaLight(0xffffff,power,w,h);l.position.set(x,y,z);l.lookAt(0,0,0);scene.add(l);}
area(-5,7,6,4,7,.25);area(-5,8,-3,3.2,8,5.5);area(3,-6,5,7,4,6);area(5,5,-6,3,5,2);
const elevation=THREE.MathUtils.degToRad(spec.elevation);
const worldHeight=13.8;
const camera=new THREE.OrthographicCamera(-worldHeight*W/H/2,worldHeight*W/H/2,worldHeight/2,-worldHeight/2,.1,100);
camera.position.set(0,Math.sin(elevation)*20,Math.cos(elevation)*20);camera.lookAt(0,0,0);camera.updateMatrixWorld();
const forward=new THREE.Vector3();camera.getWorldDirection(forward);
model.quaternion.setFromAxisAngle(forward,THREE.MathUtils.degToRad(spec.roll));
const right=new THREE.Vector3().setFromMatrixColumn(camera.matrixWorld,0),up=new THREE.Vector3().setFromMatrixColumn(camera.matrixWorld,1);
const targetX=(1190/W-.5)*worldHeight*W/H,targetY=(.5-222/H)*worldHeight;
const placement=new THREE.Group();placement.name='Hero_composition';placement.position.copy(right.clone().multiplyScalar(targetX).add(up.clone().multiplyScalar(targetY)));placement.add(model);scene.add(placement);
// Move studio lighting with the model, so the composition shift does not change material response.
for(const child of scene.children){if(child.isLight && child.type==='RectAreaLight'){child.userData.localPosition=child.position.clone();child.position.add(placement.position);child.lookAt(placement.position);}}
renderer.render(scene,camera);
function capture() {
  // 3x MSAA render -> 2x PNG; alpha is resampled together with color by the browser.
  const output=document.createElement('canvas');output.width=W*2;output.height=H*2;
  const context=output.getContext('2d');context.imageSmoothingEnabled=true;context.imageSmoothingQuality='high';
  context.drawImage(renderer.domElement,0,0,output.width,output.height);
  return output.toDataURL('image/png');
}
window.ufo3d={
  ready:true,spec,
  render(angle=spec.elevation, roll=spec.roll, inspection=false){
    const frameHeight=inspection?9:worldHeight;camera.left=-frameHeight*W/H/2;camera.right=frameHeight*W/H/2;camera.top=frameHeight/2;camera.bottom=-frameHeight/2;camera.updateProjectionMatrix();
    const e=THREE.MathUtils.degToRad(angle);camera.position.set(0,Math.sin(e)*20,Math.cos(e)*20);camera.lookAt(0,0,0);camera.updateMatrixWorld();
    camera.getWorldDirection(forward);model.quaternion.setFromAxisAngle(forward,THREE.MathUtils.degToRad(roll));
    right.setFromMatrixColumn(camera.matrixWorld,0);up.setFromMatrixColumn(camera.matrixWorld,1);
    placement.position.copy(inspection?new THREE.Vector3():right.clone().multiplyScalar(targetX).add(up.clone().multiplyScalar(targetY)));
    for(const child of scene.children)if(child.userData.localPosition){child.position.copy(child.userData.localPosition).add(placement.position);child.lookAt(placement.position);}
    renderer.render(scene,camera);return capture();
  },
  async export(){
    const original=model.quaternion.clone();model.quaternion.identity();model.updateMatrixWorld(true);
    const data=await new GLTFExporter().parseAsync(model,{binary:true});
    model.quaternion.copy(original);model.updateMatrixWorld(true);renderer.render(scene,camera);
    const bytes=new Uint8Array(data);let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(binary);
  },
  inspect(){
    model.updateWorldMatrix(true,true);
    const openings=windows.children.map(g=>{
      const origin=g.getWorldPosition(new THREE.Vector3());
      const normal=new THREE.Vector3(0,0,1).applyQuaternion(g.getWorldQuaternion(new THREE.Quaternion()));
      const ray=new THREE.Raycaster(origin.clone().addScaledVector(normal,.2),normal.clone().negate(),0,.4);
      return{name:g.name,position:g.position.toArray(),...g.userData,holeClear:ray.intersectObject(undersideMesh).length===0};
    });
    return{windows:openings,meshCount:model.getObjectsByProperty('isMesh',true).length};
  }
};
