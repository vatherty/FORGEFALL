import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { buildOptic, buildMuzzle, buildMagazine, buildStock, buildAccent } from './attachments.mjs';

// GLTFExporter converts its binary Blob through FileReader, which Node lacks.
class NodeFileReader {
  result = null;
  onloadend = null;
  async readAsArrayBuffer(blob) {
    this.result = await blob.arrayBuffer();
    this.onloadend?.();
  }
  async readAsDataURL(blob) {
    this.result = `data:${blob.type};base64,${Buffer.from(await blob.arrayBuffer()).toString('base64')}`;
    this.onloadend?.();
  }
}
globalThis.FileReader ??= NodeFileReader;

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, '../../assets/models/weapons/attachments');
const variants = [
  ['optic_iron', buildOptic, 'iron'],
  ['optic_reflex', buildOptic, 'reflex'],
  ['optic_scope', buildOptic, 'scope'],
  ['muzzle_brake', buildMuzzle, 'brake'],
  ['muzzle_suppressor', buildMuzzle, 'suppressor'],
  ['muzzle_launcher_cup', buildMuzzle, 'launcher_cup'],
  ['magazine_box', buildMagazine, 'box'],
  ['magazine_drum', buildMagazine, 'drum'],
  ['stock_solid', buildStock, 'solid'],
  ['stock_folding', buildStock, 'folding'],
  ['accent_heat_shield', buildAccent, 'heat_shield'],
  ['accent_hazard_stripe', buildAccent, 'hazard_stripe'],
  ['accent_stencil', buildAccent, 'stencil'],
];

await fs.mkdir(outDir, { recursive: true });
const exporter = new GLTFExporter();
for (const [id, build, type] of variants) {
  const model = build(THREE, { type });
  if (!(model instanceof THREE.Group)) throw new TypeError(`${id} did not return a THREE.Group`);
  model.name = `Attachment_${id}`;
  let meshes = 0;
  model.traverse((node) => {
    if (node.isMesh) meshes++;
  });
  if (meshes < 1 || meshes > 30) throw new RangeError(`${id} has ${meshes} meshes; expected 1–30`);
  const data = await exporter.parseAsync(model, { binary: true, onlyVisible: true });
  if (!(data instanceof ArrayBuffer)) throw new TypeError(`${id} export did not produce binary GLB`);
  const bytes = Buffer.from(data);
  if (bytes.toString('ascii', 0, 4) !== 'glTF') throw new Error(`${id} has invalid GLB header`);
  await fs.writeFile(path.join(outDir, `${id}.glb`), bytes);
  console.log(`${id}: ${meshes} meshes, ${bytes.length} bytes`);
}
