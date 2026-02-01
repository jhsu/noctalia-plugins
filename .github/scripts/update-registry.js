#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const ROOT_DIR = process.cwd();
const REGISTRY_FILE = path.join(ROOT_DIR, 'registry.json');

// Fields to extract from manifest.json
const MANIFEST_FIELDS = [
  'id',
  'name', 
  'version',
  'author',
  'description',
  'repository',
  'minNoctaliaVersion',
  'tags'
];

// Additional fields with defaults
const DEFAULTS = {
  official: false,
  license: 'MIT'
};

function findManifests(dir) {
  const manifests = [];
  
  const items = fs.readdirSync(dir, { withFileTypes: true });
  
  for (const item of items) {
    if (item.isDirectory() && !item.name.startsWith('.') && item.name !== 'node_modules') {
      const manifestPath = path.join(dir, item.name, 'manifest.json');
      if (fs.existsSync(manifestPath)) {
        try {
          const content = fs.readFileSync(manifestPath, 'utf8');
          const manifest = JSON.parse(content);
          manifests.push({
            ...manifest,
            _folder: item.name
          });
        } catch (err) {
          console.error(`Error parsing ${manifestPath}:`, err.message);
        }
      }
    }
  }
  
  return manifests;
}

function loadRegistry() {
  if (!fs.existsSync(REGISTRY_FILE)) {
    return { version: 1, plugins: [] };
  }
  
  try {
    const content = fs.readFileSync(REGISTRY_FILE, 'utf8');
    return JSON.parse(content);
  } catch (err) {
    console.error('Error loading registry.json:', err.message);
    return { version: 1, plugins: [] };
  }
}

function buildRegistryEntry(manifest, existingPlugin = null) {
  const entry = {};
  
  // Copy fields from manifest
  for (const field of MANIFEST_FIELDS) {
    if (manifest[field] !== undefined) {
      entry[field] = manifest[field];
    }
  }
  
  // Preserve existing official/license if present, otherwise use defaults
  entry.official = existingPlugin?.official ?? DEFAULTS.official;
  entry.license = existingPlugin?.license ?? DEFAULTS.license;
  
  // Always update lastUpdated
  entry.lastUpdated = new Date().toISOString();
  
  return entry;
}

function updateRegistry() {
  console.log('Scanning for manifest.json files...');
  
  const manifests = findManifests(ROOT_DIR);
  console.log(`Found ${manifests.length} manifest(s)`);
  
  const registry = loadRegistry();
  const existingPlugins = new Map(registry.plugins.map(p => [p.id, p]));
  
  const newPlugins = [];
  
  for (const manifest of manifests) {
    const existing = existingPlugins.get(manifest.id);
    const entry = buildRegistryEntry(manifest, existing);
    
    if (existing) {
      const hasChanged = MANIFEST_FIELDS.some(field => {
        return JSON.stringify(existing[field]) !== JSON.stringify(entry[field]);
      });
      
      if (hasChanged) {
        console.log(`Updating plugin: ${manifest.id}`);
      } else {
        console.log(`No changes for plugin: ${manifest.id}`);
      }
    } else {
      console.log(`Adding new plugin: ${manifest.id}`);
    }
    
    newPlugins.push(entry);
  }
  
  // Sort plugins by id for consistency
  newPlugins.sort((a, b) => a.id.localeCompare(b.id));
  
  // Check for removed plugins
  const newIds = new Set(newPlugins.map(p => p.id));
  for (const [id, plugin] of existingPlugins) {
    if (!newIds.has(id)) {
      console.log(`Removing plugin (no manifest found): ${id}`);
    }
  }
  
  registry.plugins = newPlugins;
  
  // Write registry.json
  fs.writeFileSync(REGISTRY_FILE, JSON.stringify(registry, null, 2) + '\n');
  console.log(`Registry updated: ${newPlugins.length} plugin(s)`);
}

updateRegistry();
