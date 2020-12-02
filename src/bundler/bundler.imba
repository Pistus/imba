import chokidar from 'chokidar'

const esbuild = require 'esbuild'
const fs = require 'fs'
const path = require 'path'
const utils = require './utils'

import {Server} from './server'
import {Logger} from './logger'
import {Bundle} from './bundle'

export class Bundler
	def constructor config, options
		cwd = options.cwd
		config = config
		options = options
		bundles = []
		sourceIdMap = {}
		watcher = options.watch ? chokidar.watch([]) : null
		log = new Logger
		
		env = options.env or process.env.NODE_ENV or 'development'
		env = 'development' if env == 'dev' or options.dev
		env = 'production' if env == 'prod' or options.prod

		manifestpath = path.resolve(outdir,'manifest.json')

		try
			manifest = JSON.parse(fs.readFileSync(manifestpath,'utf-8'))
			sourceIdMap = manifest.idmap or {}
		catch
			manifest = {}

		#cache = {}
		#dirtyInputs = new Set
		#watchedFiles = {}
		#timestamps = {}

		return self

	def absp ...src
		path.resolve(cwd,...src)

	def relp src
		path.relative(cwd,src)

	get puburl do config.puburl or '/assets/'
	get srcdir do config.srcdir or './src'
	get outdir do config.outdir or './build'
	get pubdir do config.pubdir or outdir + '/public'  # './build/public'
	get libdir do config.libdir or outdir + '/server'  # './build/server'

	get dev?
		env == 'development'

	get prod?
		env == 'production'

	def sourceIdForPath src
		let map = sourceIdMap
		src = relp(src)

		unless map[src]
			let gen = #sourceIdGenerator ||= utils.idGenerator!	
			let nr = Object.keys(map).length
			map[src] = gen(nr) + "0"

		return map[src]

	def parseEntryPoints item
		if typeof item == 'string'
			return parseEntryPoints([item])
		if item isa Array
			let files = []
			for entry,i in item
				if entry.indexOf('*') >= 0
					let paths = await utils.expandPath(entry)
					files.push(...paths)
				else
					files.push(entry)

			return files
		elif item and item.entryPoints
			parseEntryPoints(item.entryPoints)

	def time name = 'default'
		let now = Date.now!
		let prev = #timestamps[name] or now
		let diff = now - prev
		#timestamps[name] = now		
		return diff
	
	def timed name = 'default'
		let str = "time {name}: {time(name)}"

	get client
		bundles.find do $1.name == 'client'
		
	def setup
		let entries = []
		let shared = {}
		for key in ['node','browser']
			if let cfg = config[key]
				# first merge in defaults?
				if typeof cfg == 'string' or cfg isa Array
					cfg = {entryPoints: cfg}

				cfg.platform = key
				cfg.entryPoints = await parseEntryPoints(cfg.entryPoints)
				cfg = Object.assign({},config,options,cfg)
				config[key] = cfg
				entries.push(cfg)

		if config.entries
			for own key,value of config.entries
				continue if value.skip
				let paths = await parseEntryPoints(value.entryPoints or key)
				let cfg = Object.assign({},config,options,{entryPoints: paths},value)
				cfg.platform ||= 'browser'
				entries.push cfg

		for cfg in entries
			# use default loaders by default
			cfg.loader = Object.assign({},utils.defaultLoaders,cfg.loader or {})
			cfg.format = 'cjs' if cfg.platform == 'node' and !cfg.format

		bundles = entries.map do new Bundle(self,$1)
		for bundle in bundles
			await bundle.setup!

		if watcher
			watcher.on('change') do(src,stats)
				#dirtyInputs.add(relp(src))
				clearTimeout(#rebuildTimeout)
				# only rebuild if a rebuild is not already ongoing?
				#rebuildTimeout = setTimeout(&,50) do rebuild!
		
		if options.serve
			server = new Server(self)
			server.start!
		return self

	def run
		time 'build'
		let builds = for bundle in bundles
			bundle.build!
		await Promise.all(builds)
		write!
		timed 'build'

	def rebuilt bundle
		self

	def rebuild
		time 'rebuild'
		clearTimeout(#rebuildTimeout)
		let changes = Array.from(#dirtyInputs)
		#dirtyInputs.clear!

		let dirtyBundles = new Set

		for bundle in bundles
			for input in changes
				if bundle.inputs[input]
					dirtyBundles.add(bundle)

		log.info 'rebuilding'

		# await Promise.all Array.from(dirtyBundles).map do $1.rebuild!
		let awaits = for item of dirtyBundles
			item.rebuild!

		await Promise.all(awaits) 
		log.info 'finished rebuilding in %ms',time('rebuild')

		write!
		self

	def write bundles = self.bundles
		let watch = new Set
		# watch / unwatch
		time 'watch'
		for bundle in bundles
			for own src,value of bundle.inputs
				# TODO start watching essentially all files instead?
				if !src.match(/^[\w\-]+\:/) and src.match(/\.(imba|css|svg)/)
					watch.add( absp(src) )

		for file in Array.from(watch)
			if #watchedFiles[file] =? yes
				watcher..add(file)
		timed 'watch'
		
		let filesToWrite = []
		let manifest = {
			files: {}
			urls: {}
			assets: {}
			idmap: sourceIdMap
		}

		let prevFiles = self.files or []

		let files = []
		let sheets = []
		# go through output files to actually 
		for bundle in bundles
			for file in bundle.files
				
				files.push(file)
				if file.path.match(/\.css$/)
					sheets.push(file)

			if options.verbose
				manifest.bundles ||= []
				manifest.bundles.push(bundle.meta)

		time 'writeFiles'

		let sharedcss = []

		for sheet in sheets
			sharedcss.push(...sheet.contents.split("/* chunk:end */"))
		
		let sheetbody = sharedcss.filter(do(v,i) sharedcss.indexOf(v) == i).join('\n')
		let sheethash = utils.createHash(sheetbody)

		files.push {
			contents: sheetbody
			hash: sheethash
			path: path.resolve(pubdir,"all.css")
			hashedPath: path.resolve(pubdir,"all.{sheethash}.css")
		}

		for file in files
			file.writePath = dev? ? file.path : file.hashedPath
			let prev = prevFiles.find do $1.path == file.path
			let src = relp(file.path)
			let pub = path.relative(pubdir,file.path)
			let hashpub = path.relative(pubdir,file.hashedPath)

			let entry = manifest.files[src] = {
				hash: file.hash
				path: file.writePath
				#file: file
			}
			
			let url = puburl + pub
			let redir = dev? ? "{url}?v={file.hash}" : puburl + hashpub

			# better way to check whether file is in public path?
			if !pub.match(/^\.\.?\//)
				entry.url = redir
				file.url = redir
				manifest.urls[url] = src

				manifest.assets[pub] = {
					url: redir
					path: file.writePath
					hash: file.hash
				}

			if !prev or prev.hash != file.hash
				filesToWrite.push(file)

		let fsp = fs.promises
		let writes = []
		for file in filesToWrite
			let dest = file.writePath
			let link = dest != file.path and file.path
			let size = (file.contents or file.text).length
			log.success 'write %path %kb',relp(dest),size

			await utils.ensureDir(dest)
			let promise = fsp.writeFile(dest,file.contents or file.text)
			
			if link
				promise = promise.then do
					try
						await fsp.access(link,fs.constants.R_OK)
						await fsp.unlink(link)
					fsp.symlink(dest,link)
			writes.push promise

		# could write to a virtual dir as well?
		await Promise.all(writes)
		timed 'writeFiles'

		self.files = files
		
		if writes.length
			# write the manifest
			await writeManifest(manifest)
			server.updated(filesToWrite) if server

		yes

	def writeManifest manifest
		let dest = manifestpath
		let json = JSON.stringify(manifest,null,2)
		self.manifest = manifest
		await utils.ensureDir(dest)
		fs.promises.writeFile(dest,json)
		log.success 'write %path %kb',relp(dest),json.length