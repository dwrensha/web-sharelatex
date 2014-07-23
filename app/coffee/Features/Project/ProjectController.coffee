async = require("async")
logger = require("logger-sharelatex")
projectDeleter = require("./ProjectDeleter")
projectDuplicator = require("./ProjectDuplicator")
projectCreationHandler = require("./ProjectCreationHandler")
editorController = require("../Editor/EditorController")
metrics = require('../../infrastructure/Metrics')
sanitize = require('sanitizer')
Project = require('../../models/Project').Project
User = require('../../models/User').User
TagsHandler = require("../Tags/TagsHandler")
SubscriptionLocator = require("../Subscription/SubscriptionLocator")
_ = require("underscore")
Settings = require("settings-sharelatex")
SecurityManager = require("../../managers/SecurityManager")

module.exports =

	gotoSandstormProject : (req, res, next = (error)->) ->
		Project.findOne {}, (err, project) ->
			if err?
				console.log("ERROR GETTING PROJECT: " + err)
				next(err)
			if !project?
				projectCreationHandler.createSandstormProject req.session.user._id, "ShareLaTeX project", (error, project) ->
					return res.redirect('/project/' + project._id)
			else
				return res.redirect ('/project/' + project._id)

	deleteProject: (req, res) ->
		project_id = req.params.Project_id
		forever    = req.query?.forever?
		logger.log project_id: project_id, forever: forever, "received request to delete project"

		if forever
			doDelete = projectDeleter.deleteProject
		else
			doDelete = projectDeleter.archiveProject

		doDelete project_id, (err)->
			if err?
				res.send 500
			else
				res.send 200

	restoreProject: (req, res) ->
		project_id = req.params.Project_id
		logger.log project_id:project_id, "received request to restore project"
		projectDeleter.restoreProject project_id, (err)->
			if err?
				res.send 500
			else
				res.send 200

	cloneProject: (req, res)->
		metrics.inc "cloned-project"
		project_id = req.params.Project_id
		projectName = req.body.projectName
		logger.log project_id:project_id, projectName:projectName, "cloning project"
		if !req.session.user?
			return res.send redir:"/register"
		projectDuplicator.duplicate req.session.user, project_id, projectName, (err, project)->
			if err?
				logger.error err:err, project_id: project_id, user_id: req.session.user._id, "error cloning project"
				return next(err)
			res.send(project_id:project._id)


	newProject: (req, res)->
		user = req.session.user
		projectName = sanitize.escape(req.body.projectName)
		template = sanitize.escape(req.body.template)
		logger.log user: user, type: template, name: projectName, "creating project"
		async.waterfall [
			(cb)->
				if template == 'example'
					projectCreationHandler.createExampleProject user._id, projectName, cb
				else
					projectCreationHandler.createBasicProject user._id, projectName, cb
		], (err, project)->
			if err?
				logger.error err: err, project: project, user: user, name: projectName, type: template, "error creating project"
				res.send 500
			else
				logger.log project: project, user: user, name: projectName, type: template, "created project"
				res.send {project_id:project._id}


	renameProject: (req, res)->
		project_id = req.params.Project_id
		newName = req.body.newProjectName
		editorController.renameProject project_id, newName, (err)->
			if err?
				logger.err err:err, project_id:project_id, newName:newName, "problem renaming project"
				res.send 500
			else
				res.send 200

	projectListPage: (req, res, next)->
		timer = new metrics.Timer("project-list")
		user_id = req.session.user._id
		async.parallel {
			tags: (cb)->
				TagsHandler.getAllTags user_id, cb
			projects: (cb)->
				Project.findAllUsersProjects user_id, 'name lastUpdated publicAccesLevel', cb
			}, (err, results)->
				if err?
					logger.err err:err, "error getting data for project list page"
					return res.send 500
				logger.log results:results, user_id:user_id, "rendering project list"
				viewModel = _buildListViewModel results.projects[0], results.projects[1], results.projects[2], results.tags[0], results.tags[1]
				if Settings?.algolia?.institutions?.app_id? and Settings?.algolia?.institutions?.api_key?
					viewModel.showUserDetailsArea = true
					viewModel.algolia_api_key = Settings.algolia.institutions.api_key
					viewModel.algolia_app_id = Settings.algolia.institutions.app_id
				else
					viewModel.showUserDetailsArea = false
				res.render 'project/list', viewModel
				timer.done()

	archivedProjects: (req, res, next)->
		user_id = req.session.user._id
		projectDeleter.findArchivedProjects user_id, 'name lastUpdated publicAccesLevel', (error, projects) ->
			return next(error) if error?
			logger.log projects: projects, user_id:user_id, "rendering archived project list"
			viewModel = _buildListViewModel projects, [], [], [], {}
			res.render 'project/archived', viewModel

	loadEditor: (req, res, next)->
		timer = new metrics.Timer("load-editor")
		if !Settings.editorIsOpen
			return res.render("general/closed", {title:"updating site"})

		if req.session.user?
			user_id = req.session.user._id 
			anonymous = false
		else
			anonymous = true
			user_id = 'openUser'
		
		project_id = req.params.Project_id
	
		async.parallel {
			project: (cb)->
				Project.findPopulatedById project_id, cb
			user: (cb)->
				if user_id == 'openUser'
					cb null, defaultSettingsForAnonymousUser(user_id)
				else
					User.findById user_id, cb
			subscription: (cb)->
				if user_id == 'openUser'
					return cb()
				SubscriptionLocator.getUsersSubscription user_id, cb
		}, (err, results)->
			if err?
				logger.err err:err, "error getting details for project page"
				return next err
			project = results.project
			user = results.user
			subscription = results.subscription

			SecurityManager.userCanAccessProject user, project, (canAccess, privilegeLevel)->
				if !canAccess
					return res.send 401

				if subscription? and subscription.freeTrial? and subscription.freeTrial.expiresAt?
					allowedFreeTrial = !!subscription.freeTrial.allowed || true

				res.render 'project/editor',
					title:  project.name
					priority_title: true
					bodyClasses: ["editor"]
					project : project
					userObject : JSON.stringify({
						id    : user.id
						email : user.email
						first_name : user.first_name
						last_name  : user.last_name
						referal_id : user.referal_id
						subscription :
							freeTrial: {allowed: allowedFreeTrial}
					})
					userSettingsObject: JSON.stringify({
						mode  : user.ace.mode
						theme : user.ace.theme
						project_id : project._id
						fontSize : user.ace.fontSize
						autoComplete: user.ace.autoComplete
						spellCheckLanguage: user.ace.spellCheckLanguage
						pdfViewer : user.ace.pdfViewer
						docPositions: {}
						oldHistory: !!user.featureSwitches?.oldHistory
					})
					sharelatexObject : JSON.stringify({
						siteUrl: Settings.siteUrl,
						jsPath: res.locals.jsPath
					})
					privilegeLevel: privilegeLevel
					loadPdfjs: (user.ace.pdfViewer == "pdfjs")
					chatUrl: Settings.apis.chat.url
					anonymous: anonymous
					languages: Settings.languages
					timer.done()

defaultSettingsForAnonymousUser = (user_id)->
	id : user_id
	ace:
		mode:'none'
		theme:'textmate'
		fontSize: '12'
		autoComplete: true
		spellCheckLanguage: ""
		pdfViewer: ""
	subscription:
		freeTrial:
			allowed: true
	featureSwitches:
		dropbox: false
		trackChanges: false

_buildListViewModel = (projects, collabertions, readOnlyProjects, tags, tagsGroupedByProject)->
	for project in projects
		project.accessLevel = "owner"
	for project in collabertions
		project.accessLevel = "readWrite"
	for project in readOnlyProjects
		project.accessLevel = "readOnly"
	projects = projects.concat(collabertions).concat(readOnlyProjects)
	projects = projects.map (project)->
		project.tags = tagsGroupedByProject[project._id] || []
		return project
	tags = _.sortBy tags, (tag)->
		-tag.project_ids.length
	sortedProjects = _.sortBy projects, (project)->
		return - project.lastUpdated

	return {
		title:'Your Projects'
		priority_title: true
		projects: sortedProjects
		tags:tags
		projectTabActive: true
	}