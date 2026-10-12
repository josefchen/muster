export default {
  fetch(request) {
    const url = new URL(request.url);
    url.hostname = "agentmuster.app";
    return Response.redirect(url.toString(), 301);
  },
};
