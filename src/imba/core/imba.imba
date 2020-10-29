global class Imba

	def constructor parent,state = {}
		#parent = parent
		#state = state
		self

	get state
		#state

	get version
		'2.0.0-alpha.97'

	get window
		#window or global.window

	get document
		#document or global.document

	get dom
		self.window

	get clearInterval
		global.clearInterval
	
	get clearTimeout
		global.clearTimeout

	def setTimeout fn,ms
		setTimeout(&,ms) do
			fn!
			commit!
			return

	def setInterval fn,ms
		setInterval(&,ms) do
			fn!
			commit!
			return

	def run cb
		cb()

	def fork cb
		cb() if cb
		self

global.imba = global.#imba = new Imba