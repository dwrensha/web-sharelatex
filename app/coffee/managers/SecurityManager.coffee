logger = require('logger-sharelatex')
crypto = require 'crypto'
Assert = require 'assert'
Settings = require 'settings-sharelatex'
User = require('../models/User').User
Project = require('../models/Project').Project
ErrorController = require("../Features/Errors/ErrorController")
AuthenticationController = require("../Features/Authentication/AuthenticationController")
_ = require('underscore')
metrics = require('../infrastructure/Metrics')
querystring = require('querystring')
async = require "async"

module.exports = SecurityManager =
	restricted : (req, res, next)->
		if req.session.user?
			res.render 'user/restricted',
				title:'restricted'
		else
			logger.log "user not logged in and trying to access #{req.url}, being redirected to login"
			res.redirect '/register'

	getCurrentUser: (req, callback) ->
		if req.session.user?
			User.findById req.session.user._id, callback
		else
			callback null, null

	requestCanAccessMultipleProjects: (req, res, next) ->
		project_ids = req.query.project_ids?.split(",")
		jobs = []
		for project_id in project_ids or []
			do (project_id) ->
				jobs.push (callback) ->
					# This is a bit hacky - better to have an abstracted method
					# that we can pass project_id to, but this whole file needs
					# a serious refactor ATM.
					req.params.Project_id = project_id
					SecurityManager.requestCanAccessProject req, res, (error) ->
						delete req.params.Project_id
						callback(error)
		async.series jobs, next

	requestCanAccessProject : (req, res, next)->
		doRequest = (req, res, next) ->
			next()
		if arguments.length > 1
			options =
				allow_auth_token: false
			doRequest.apply(this, arguments)
		else
			options = req
			return doRequest

	requestHasWritePermission: (req) ->
		permissionsArray = req.headers['x-sandstorm-permissions'].split(',');
		return (permissionsArray.indexOf("write") != -1)

	getPrivilegeLevel: (req) ->
		if SecurityManager.requestHasWritePermission (req)
			return "readAndWrite"
		else
			return "readOnly"

	requestCanModifyProject : (req, res, next)->
		if SecurityManager.requestHasWritePermission(req)
			next()
		else
			logger.log "user_id: #{user?._id} email: #{user?.email} can not modify project redirecting to restricted page"
			res.redirect('/restricted')

	requestIsOwner : (req, res, next)->
		getRequestUserAndProject req, res, {}, (err, user, project)->
			if userIsOwner user, project || user.isAdmin
				next()
			else
				logger.log user_id: user?._id, email: user?.email, "user is not owner of project redirecting to restricted page"
				res.redirect('/restricted')

	requestIsAdmin : isAdmin = (req, res, next)->
		logger.log "checking if user is admin"
		user = req.session.user
		if(user? && user.isAdmin)
			logger.log user: user, "User is admin"
			next()
		else
			res.redirect('/restricted')
			logger.log user:user, "is not admin redirecting to restricted page"

	userCanAccessProject : userCanAccessProject = (user, project, callback)=>
		if !user?
			user = {_id:'anonymous-user'}
		if !project?
			callback false
		logger.log user:user, project:project, "Checking if can access"
		if userIsOwner user, project
			callback true, "owner"
		else if userIsCollaberator user, project
			callback true, "readAndWrite"
		else if userIsReadOnly user, project
			callback true, "readOnly"
		else if user.isAdmin
			logger.log  user:user, project:project, "user is admin and can access project"
			callback true, "owner"
		else if project.publicAccesLevel == "readAndWrite"
			logger.log  user:user, project:project, "project is a public read and write project"
			callback true, "readAndWrite"
		else if project.publicAccesLevel == "readOnly"
			logger.log  user:user, project:project,  "project is a public read only project"
			callback true, "readOnly"
		else
			metrics.inc "security.denied"
			logger.log  user:user, project:project, "Security denied - user can not enter project"
			callback false

	userIsOwner : userIsOwner = (user, project)->
		if !user?
			return false
		else
			userId = user._id+''
			ownerRef = getProjectIdFromRef(project.owner_ref)
			if userId == ownerRef
				true
			else
				false

	userIsCollaberator : userIsCollaberator = (user, project)->
		if !user?
			return false
		else
			userId = user._id+''
			result = false
			_.each project.collaberator_refs, (colabRef)->
				colabRef = getProjectIdFromRef(colabRef)
				if colabRef == userId
					result = true
			return result

	userIsReadOnly : userIsReadOnly = (user, project)->
		if !user?
			return false
		else
			userId = user._id+''
			result = false
			_.each project.readOnly_refs, (readOnlyRef)->
				readOnlyRef = getProjectIdFromRef(readOnlyRef)
				
				if readOnlyRef == userId
					result = true
			return result

getRequestUserAndProject = (req, res, options, callback)->
	project_id = req.params.Project_id
	Project.findById project_id, 'name owner_ref readOnly_refs collaberator_refs publicAccesLevel archived', (err, project)=>
		if err?
			logger.err err:err, "error getting project for security check"
			return callback err
		AuthenticationController.getLoggedInUser req, options, (err, user)=>
			if err?
				logger.err err:err, "error getting last logged in user for security check"
			callback err, user, project

getProjectIdFromRef = (ref)->
	if !ref?
		return null
	else if ref._id?
		return ref._id+''
	else
		return ref+''


