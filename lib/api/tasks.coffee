"use strict"

request = require("request")
url = require("url")
logger = require("../logger")

stop_job = (running_job)->
  logger.info running_job.toJSON()
  url_str = url.format(
    protocol: "http"
    hostname: running_job.get("ip")
    port: running_job.get("port")
    pathname: "/api/0/jobs/#{running_job.id}/stop"
  )
  request.get(url_str, (e, r, body)->)
  logger.info "Stop running job:#{running_job.id}."


exports = module.exports =
  add: (req, res, next) ->
    name = req.param("name")
    description = req.param("description") or ""
    jobs = req.param("jobs")
    return next(new Error("Invalid parameters!")) if not name?  or jobs not instanceof Array or jobs.length is 0

    properties = ["environ", "device_filter", "repo_url", "repo_branch", "repo_username", "repo_passowrd"]
    jobs.forEach (job, index) ->
      for prop in properties when prop not of job and req.param(prop)?
        job[prop] = req.param(prop)
      job["environ"] ?= {}
      job["device_filter"] ?= {}
      job["r_type"] ?= "none"
      job["r_job_nos"] ?= []
      job["status"] = "new"
      job["no"] ?= index

    req.db.models.task.create [{name: name, description: description, creator_id: req.user.id}], (err, tasks) ->
      return next(err) if err?
      job.task_id = tasks[0].id for job in jobs
      req.db.models.job.create jobs, (err, jobs) ->
        return next(err) if err?
        tasks[0].jobs = jobs
        res.json tasks[0]
        req.redis.publish "db.task", JSON.stringify(method: "add", task: tasks[0].id)

  get: (req, res, next) ->
    id = req.params.id
    req.db.models.task.get id, (err, task) ->
      return next(err) if err?
      res.json task

  list: (req, res, next) ->
    page = Number(req.param("page")) or 0
    page_count = Number(req.param("page_count")) or 16
    req.db.models.task.find().order("-id").offset(page*page_count).limit(page_count).all (err, tasks) ->
      return next(err) if err?
      res.json tasks

  remove: (req, res, next) ->
    id = Number(req.params.id)
    req.db.models.task.get id, (err, task) ->
      return next(err) if err?
      # calcel running jobs of the task
      task.jobs.forEach (job) ->
        stop_job(req.zk.models.jobs.get(job.id)) if req.zk.models.jobs.get(job.id)?  # stop the running job
      task.remove (err) ->
        return next(err) if err?
        req.db.models.job.find(task_id: id).remove (err) ->
          return next(err) if err?
          res.send 200
          req.redis.publish "db.task", JSON.stringify(method: "delete", task: id)
          logger.info "Task:#{id} removed."

  cancel: (req, res, next) ->
    id = Number(req.params.id)
    req.db.models.job.find({task_id: id, status: ["new", "started"]}).each((job) ->
      job.status = "cancelled"
      stop_job(req.zk.models.jobs.get(job.id)) if req.zk.models.jobs.get(job.id)?  # stop the running job
    ).save (err) ->
      req.redis.publish "db.task", JSON.stringify(method: "cancel", task: id)
      res.send 200
      logger.info "Task:#{id} cancelled."

  restart: (req, res, next) ->
    id = Number(req.params.id)
    req.db.models.job.find({task_id: id}).each((job) ->
      job.status = "new"
      stop_job(req.zk.models.jobs.get(job.id)) if req.zk.models.jobs.get(job.id)?  # stop the running job
    ).save (err) ->
      req.redis.publish "db.task", JSON.stringify(method: "restart", task: id)
      res.send 200
      logger.info "Task:#{id} re-started."
